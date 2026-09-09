from __future__ import annotations

import concurrent.futures
import html
import re
import threading
from typing import Any, Dict, Optional

from .gdrive import (
    build_download_info,
    file_id_from_url,
    folder_id_from_url,
    format_size,
    header_value,
    is_denied_page,
    parse_folder_page,
    parse_size_from_content_range,
)

_MAX_TREE_DEPTH = 100
_MAX_TREE_ITEMS = 5000
_MAX_WORKERS = 8
_PAGE_SIZE = 100
_PROBE_TREE_LIMIT = 50

# 全局信号量：无论多少工作线程，真正并发在途的 HTTP 请求不超过 _MAX_WORKERS。
# 避免树/分页并行时 8x8=64 个请求同时打给 Google 与宿主，也避免宿主侧意见。
_REQUEST_SEMAPHORE = threading.BoundedSemaphore(_MAX_WORKERS)

_USER_AGENT = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
    "AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/124.0.0.0 Safari/537.36"
)


def _fetch(
    context: Any,
    url: str,
    max_bytes: int,
    route: str = "auto",
    extra_headers: Optional[Dict[str, str]] = None,
) -> dict[str, Any]:
    with _REQUEST_SEMAPHORE:
        headers: Dict[str, str] = {
            "User-Agent": _USER_AGENT,
            "Accept-Encoding": "identity",
        }
        if extra_headers:
            headers.update(extra_headers)
        return context.request({
        "url": url,
        "method": "GET",
        "route": route,
        "timeoutMs": 20000,
        "maxBytes": max_bytes,
        "headers": headers,
    })


def resolve_download(context: Any, params: dict[str, Any]) -> dict[str, Any]:
    context.check_cancelled()
    url = str(params.get("url") or "").strip()
    route = str(params.get("route") or "auto").strip() or "auto"

    file_id = file_id_from_url(url)
    if not file_id:
        raise ValueError("无法识别谷歌网盘文件链接，请粘贴分享链接")

    context.progress(0.3, "正在获取下载地址")

    response = _fetch(
        context,
        f"https://drive.google.com/uc?export=download&id={file_id}",
        4 * 1024 * 1024,
        route,
    )

    if not response.get("ok"):
        final_url = response.get("url") or ""
        if "drive.usercontent.google.com" in final_url:
            context.progress(1.0, "解析完成")
            return {"url": final_url, "fileName": ""}
        error = response.get("error") or "请求失败"
        raise RuntimeError(f"获取下载地址失败: {error}")

    final_url = response.get("url") or ""
    body = response.get("body") or ""
    headers = response.get("headers") or {}
    content_disposition = header_value(headers, "content-disposition")

    if is_denied_page(body):
        raise RuntimeError("该文件可能未公开分享，或链接已失效")

    direct_url, file_name = build_download_info(
        file_id=file_id,
        final_url=final_url,
        body=body,
        content_disposition=content_disposition,
    )
    if not file_name:
        file_name = file_id

    context.progress(1.0, "解析完成")

    return {"url": direct_url, "fileName": file_name}


def direct_download_url(file_id: str) -> str:
    return f"https://drive.usercontent.google.com/download?id={file_id}&export=download"


def _probe_file_size(context: Any, file_id: str, route: str) -> int:
    """对公开文件发 Range 请求(1字节)取总大小，失败返回 0。

    谷歌网盘下载直链对文件支持 Range(206)，Content-Range 头带总大小；
    对需要病毒确认的大文件同样返回 206，故可正确拿到真实大小。
    """
    if not file_id:
        return 0
    try:
        response = _fetch(
            context,
            direct_download_url(file_id),
            4096,
            route,
            extra_headers={"Range": "bytes=0-0"},
        )
    except Exception:
        return 0
    if not response.get("ok"):
        return 0
    headers = response.get("headers") or {}
    return parse_size_from_content_range(
        header_value(headers, "content-range"),
    )


def _fetch_folder_page(
    context: Any,
    folder_id: str,
    route: str,
    start: int = 0,
) -> tuple[list[dict[str, object]], str]:
    url = f"https://drive.google.com/embeddedfolderview?id={folder_id}"
    if start > 0:
        url += f"&start={start}"
    response = _fetch(context, url, 8 * 1024 * 1024, route)
    if not response.get("ok"):
        raise RuntimeError(f"获取文件夹内容失败: {response.get('error') or '未知错误'}")
    body = response.get("body") or ""
    if is_denied_page(body):
        raise RuntimeError("该文件夹可能未公开分享，或链接已失效")
    items = parse_folder_page(body)
    title_match = re.search(r"<title>([^<]*)</title>", body, re.IGNORECASE)
    folder_name = html.unescape(title_match.group(1)).strip() if title_match else ""
    return items, folder_name


def _list_folder_items(
    context: Any,
    folder_id: str,
    route: str,
    page_size: int = _PAGE_SIZE,
    max_pages: int = 50,
    probe_limit: Optional[int] = None,
) -> tuple[list[dict[str, object]], str]:
    """并行分页拉取一个文件夹的全部条目（自适应探测）。

    先在单个请求拿到首页；若首页条目 < page_size（绝大多数文件夹），
    说明内容很少，立即返回，不浪费请求。只有首页满 100 才并行扩展后续页，
    直到出现空页或条目数不足 page_size。失败页跳过并记日志，不中断整体。
    """
    items: list[dict[str, object]] = []
    seen: set[str] = set()
    folder_name = ""
    fetched_pages: list[tuple[int, list[dict[str, object]], str]] = []

    first_items, first_name = _fetch_folder_page(context, folder_id, route, 0)
    if first_name:
        folder_name = first_name
    fetched_pages.append((0, first_items, first_name))
    for item in first_items:
        item_id = str(item.get("id") or "")
        if item_id and item_id not in seen:
            seen.add(item_id)
            items.append(item)

    if len(first_items) < page_size:
        _probe_item_sizes(context, items, route, limit=probe_limit)
        return items, folder_name

    start_idx = 1
    while start_idx < max_pages:
        context.check_cancelled()
        batch = range(start_idx, min(start_idx + _MAX_WORKERS, max_pages))
        offsets = [p * page_size for p in batch]
        start_idx = batch.stop

        def _fetch_one(offset: int) -> tuple[int, list[dict[str, object]], str]:
            try:
                page_items, page_name = _fetch_folder_page(context, folder_id, route, offset)
                return offset, page_items, page_name
            except Exception as error:
                context.log(f"拉取分页失败({offset}): {error}")
                return offset, [], ""

        with concurrent.futures.ThreadPoolExecutor(max_workers=_MAX_WORKERS) as executor:
            results = list(executor.map(_fetch_one, offsets))

        results.sort(key=lambda r: r[0])
        batch_has_new = False
        for offset, page_items, page_name in results:
            if page_name and not folder_name:
                folder_name = page_name
            if not page_items:
                continue
            for item in page_items:
                item_id = str(item.get("id") or "")
                if item_id and item_id in seen:
                    continue
                if item_id:
                    seen.add(item_id)
                items.append(item)
                batch_has_new = True
            fetched_pages.append((offset, page_items, page_name))

        smallest_page_count = min((len(p) for _, p, _ in results), default=0)
        if not batch_has_new or smallest_page_count < page_size:
            break

    if not folder_name:
        for offset, page_items, page_name in fetched_pages:
            if page_name:
                folder_name = page_name
                break

    _probe_item_sizes(context, items, route, limit=probe_limit)
    return items, folder_name


def _probe_item_sizes(
    context: Any,
    items: list[dict[str, object]],
    route: str,
    limit: Optional[int] = None,
) -> None:
    """对列表中的文件并行探测真实大小（Range 请求 1 字节）。

    失败自动降级：保持原 size；不中断整体解析。
    limit 用于限制单批探测数量（主要是树模式深层大目录），超限部分留空。
    """
    files = [item for item in items if item.get("type") == "file"]
    if not files:
        return
    if limit is not None and limit <= 0:
        return
    batch = files if limit is None else files[:limit]
    with concurrent.futures.ThreadPoolExecutor(max_workers=_MAX_WORKERS) as executor:

        def _one(item: dict[str, object]) -> int:
            return _probe_file_size(context, str(item.get("id") or ""), route)

        results = list(executor.map(_one, batch))
    for item, size_bytes in zip(batch, results):
        if size_bytes > 0:
            item["sizeBytes"] = size_bytes
            item["size"] = format_size(size_bytes)


def list_folder(context: Any, params: dict[str, Any]) -> dict[str, Any]:
    context.check_cancelled()
    url = str(params.get("url") or "").strip()
    route = str(params.get("route") or "auto").strip() or "auto"

    folder_id = folder_id_from_url(url)
    if not folder_id:
        raise ValueError("无法识别谷歌网盘文件夹链接，请粘贴分享链接")

    context.progress(0.05, "正在获取文件夹内容")

    items, folder_name = _list_folder_items(context, folder_id, route)

    if not items:
        raise RuntimeError("文件夹为空，或无法解析内容")

    total = len(items)
    total_bytes = 0
    for index, item in enumerate(items):
        context.check_cancelled()
        item["path"] = f"/{folder_name}" if folder_name else "/"
        if item.get("type") == "file":
            file_id = str(item.get("id") or "")
            item["downloadUrl"] = direct_download_url(file_id)
            size_bytes = int(item.get("sizeBytes") or 0)
            total_bytes += size_bytes
        context.progress(
            0.1 + 0.85 * (index + 1) / total,
            f"正在读取文件信息 {index + 1}/{total}",
        )

    context.progress(1.0, "解析完成")

    return {"folderId": folder_id, "items": items, "totalSize": total_bytes}


class _Budget:
    def __init__(self, limit: int) -> None:
        self.remaining = limit


def _collect_tree(
    context: Any,
    folder_id: str,
    route: str,
    budget: _Budget,
    path: str = "/",
) -> list[dict[str, Any]]:
    """广度优先并行解析完整目录树。

    迭代式 BFS + 单一共享线程池：每一批并行解析文件夹，把子文件夹加入
    队列继续，直到全部完成。避免递归嵌套线程池造成的死锁与线程爆炸，
    同时保持并发抓取的高吞吐。单个子文件夹失败只影响自身，不影响兄弟。
    """
    root_node: dict[str, Any] = {
        "name": "",
        "id": folder_id,
        "type": "folder",
        "size": "",
        "sizeBytes": 0,
        "path": path,
        "children": [],
        "downloadUrl": "",
        "depth": 0,
    }
    node_by_id: dict[str, dict[str, Any]] = {folder_id: root_node}
    pending: list[dict[str, Any]] = [root_node]

    with concurrent.futures.ThreadPoolExecutor(max_workers=_MAX_WORKERS) as executor:
        while pending:
            context.check_cancelled()
            if budget.remaining <= 0:
                context.log("目录内容过多，已达到上限，剩余目录已截断")
                break

            batch = pending
            pending = []

            def _load(node: dict[str, Any]) -> tuple[dict[str, Any], list[dict[str, object]]]:
                nid = str(node.get("id") or "")
                try:
                    items, folder_name = _list_folder_items(
                        context, nid, route,
                        probe_limit=_PROBE_TREE_LIMIT,
                    )
                    if folder_name:
                        node["name"] = folder_name
                    return node, items
                except Exception as error:
                    context.log(f"解析文件夹失败 {node.get('name') or nid}: {error}")
                    return node, []

            futures = {executor.submit(_load, node): node for node in batch}
            for future, node in futures.items():
                nid = str(node.get("id") or "")
                node["children"] = []
                loaded_node, items = future.result()
                current_path = node.get("path") or path
                if loaded_node.get("name"):
                    current_path = f"{current_path}/{loaded_node['name']}"
                if budget.remaining <= 0:
                    continue
                for item in items:
                    context.check_cancelled()
                    if budget.remaining <= 0:
                        context.log("目录内容过多，已达到上限，剩余目录已截断")
                        break
                    budget.remaining -= 1
                    item["path"] = current_path
                    if item.get("type") == "folder":
                        child_id = str(item.get("id") or "")
                        item["downloadUrl"] = ""
                        item["children"] = []
                        item["depth"] = int(node.get("depth") or 0) + 1
                        if child_id in node_by_id:
                            item["_reused"] = True
                        else:
                            node_by_id[child_id] = item
                            pending.append(item)
                        node["children"].append(item)
                    else:
                        item["children"] = []
                        item["depth"] = int(node.get("depth") or 0) + 1
                        file_id = str(item.get("id") or "")
                        item["downloadUrl"] = direct_download_url(file_id)
                        node["children"].append(item)

    return root_node.get("children") or []


def list_folder_tree(context: Any, params: dict[str, Any]) -> dict[str, Any]:
    context.check_cancelled()
    url = str(params.get("url") or "").strip()
    route = str(params.get("route") or "auto").strip() or "auto"

    folder_id = folder_id_from_url(url)
    if not folder_id:
        raise ValueError("无法识别谷歌网盘文件夹链接，请粘贴分享链接")

    context.progress(0.05, "正在获取完整目录树")

    budget = _Budget(_MAX_TREE_ITEMS)
    tree = _collect_tree(context, folder_id, route, budget)
    total_files = 0
    total_bytes = 0

    def _count(nodes: list[dict[str, Any]]) -> None:
        nonlocal total_files, total_bytes
        for node in nodes:
            if node.get("type") == "folder":
                _count(node.get("children") or [])
            else:
                total_files += 1
                total_bytes += int(node.get("sizeBytes") or 0)

    _count(tree)
    context.progress(1.0, "目录树解析完成")

    return {
        "folderId": folder_id,
        "tree": tree,
        "totalFiles": total_files,
        "totalSize": total_bytes,
        "truncated": budget.remaining <= 0,
    }