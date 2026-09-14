from __future__ import annotations

import concurrent.futures
import datetime
import email.utils
import html
import json
import re
import sqlite3
import threading
import time
from contextlib import closing
from pathlib import Path
from typing import Any, Dict, Optional

from .gdrive import (
    build_download_info,
    display_modified_date,
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
_CACHE_DB = Path(__file__).resolve().parent.parent / "cache" / "folders.sqlite3"
_CACHE_TTL_SECONDS = 24 * 60 * 60
_CACHE_MAX_FOLDERS = _MAX_TREE_ITEMS + 1
_CACHE_WRITE_LOCK = threading.Lock()
_cache_writes = 0

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
    context.check_cancelled()
    with _REQUEST_SEMAPHORE:
        context.check_cancelled()
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


def _parent_path(params: dict[str, Any]) -> str:
    parts = re.split(r"[/\\]+", str(params.get("parentPath") or ""))
    return "/" + "/".join(part for part in parts if part and part not in {".", ".."})


def _cached_folder_items(
    context: Any,
    folder_id: str,
    route: str,
    *,
    refresh: bool = False,
) -> tuple[list[dict[str, object]], str]:
    """One cache owner for both single-depth navigation and full-tree loading."""
    context.check_cancelled()
    legacy_items: list[dict[str, object]] = []
    if not refresh and _CACHE_DB.is_file():
        try:
            with closing(sqlite3.connect(_CACHE_DB, timeout=5)) as db:
                row = db.execute(
                    "SELECT folder_name, items_json, updated_at FROM folders "
                    "WHERE route=? AND folder_id=? AND updated_at>=?",
                    (route, folder_id, int(time.time()) - _CACHE_TTL_SECONDS),
                ).fetchone()
            if row is not None:
                items = json.loads(row[1])
                if isinstance(items, list) and all(isinstance(item, dict) for item in items):
                    if all(
                        "modifiedDisplay" in item
                        and not re.fullmatch(
                            r"\d{1,2}/\d{1,2}/\d{2}",
                            str(item.get("modifiedDisplay") or ""),
                        )
                        for item in items
                    ):
                        cached_year = datetime.datetime.fromtimestamp(int(row[2])).year
                        for item in items:
                            item["modifiedDisplay"] = display_modified_date(
                                str(item.get("modifiedDisplay") or ""), cached_year,
                            )
                        return items, str(row[0] or "")
                    legacy_items = items
        except (OSError, sqlite3.Error, ValueError, TypeError) as error:
            context.log(f"Folder cache read skipped: {error}")

    items, folder_name = _list_folder_items(context, folder_id, route)
    context.check_cancelled()
    if legacy_items:
        cached_sizes = {
            str(item.get("id") or ""): item
            for item in legacy_items
            if item.get("type") == "file" and int(item.get("sizeBytes") or 0) > 0
        }
        for item in items:
            if item.get("type") != "file" or int(item.get("sizeBytes") or 0) > 0:
                continue
            cached = cached_sizes.get(str(item.get("id") or ""))
            if cached:
                size_bytes = int(cached["sizeBytes"])
                item["sizeBytes"] = size_bytes
                item["size"] = str(cached.get("size") or format_size(size_bytes))
    _store_folder_items(context, folder_id, route, folder_name, items)
    return items, folder_name


def _store_folder_items(
    context: Any, folder_id: str, route: str, folder_name: str,
    items: list[dict[str, object]],
) -> None:
    global _cache_writes
    try:
        payload = json.dumps(items, ensure_ascii=False, separators=(",", ":"))
        _CACHE_DB.parent.mkdir(parents=True, exist_ok=True)
        with _CACHE_WRITE_LOCK, closing(sqlite3.connect(_CACHE_DB, timeout=5)) as db:
            with db:
                db.execute(
                    "CREATE TABLE IF NOT EXISTS folders ("
                    "route TEXT NOT NULL, folder_id TEXT NOT NULL, updated_at INTEGER NOT NULL, "
                    "folder_name TEXT NOT NULL, items_json TEXT NOT NULL, "
                    "PRIMARY KEY (route, folder_id))"
                )
                db.execute(
                    "INSERT OR REPLACE INTO folders "
                    "(route, folder_id, updated_at, folder_name, items_json) VALUES (?, ?, ?, ?, ?)",
                    (route, folder_id, int(time.time()), folder_name, payload),
                )
                _cache_writes += 1
                if _cache_writes % 64 == 0:
                    db.execute("DELETE FROM folders WHERE updated_at<?", (int(time.time()) - _CACHE_TTL_SECONDS,))
                    db.execute(
                        "DELETE FROM folders WHERE rowid IN ("
                        "SELECT rowid FROM folders ORDER BY updated_at DESC, rowid DESC "
                        "LIMIT -1 OFFSET ?)", (_CACHE_MAX_FOLDERS,)
                    )
    except (OSError, sqlite3.Error, TypeError, ValueError) as error:
        context.log(f"Folder cache write skipped: {error}")


def probe_folder_sizes(context: Any, params: dict[str, Any]) -> dict[str, Any]:
    """Probe only the explicitly selected files in one folder, then cache them."""
    context.check_cancelled()
    folder_id = str(params.get("folderId") or "").strip()
    route = str(params.get("route") or "auto").strip() or "auto"
    if not folder_id or not re.fullmatch(r"[-\w]+", folder_id):
        raise ValueError("无效的文件夹 ID")
    file_ids = params.get("fileIds")
    if not isinstance(file_ids, list) or not (1 <= len(file_ids) <= 64):
        raise ValueError("每批必须选择 1 至 64 个文件")
    requested = {str(value) for value in file_ids if re.fullmatch(r"[-\w]+", str(value))}
    if len(requested) != len(file_ids):
        raise ValueError("文件 ID 无效或重复")
    items, folder_name = _cached_folder_items(context, folder_id, route)
    selected = [
        item for item in items
        if item.get("type") == "file" and str(item.get("id")) in requested
    ]
    _probe_item_sizes(context, selected, route)
    context.check_cancelled()
    _store_folder_items(context, folder_id, route, folder_name, items)
    return {
        "folderId": folder_id,
        "resolvedCount": sum(int(item.get("sizeBytes") or 0) > 0 for item in selected),
        "sizes": {
            str(item.get("id")): int(item.get("sizeBytes") or 0)
            for item in selected if int(item.get("sizeBytes") or 0) > 0
        },
    }


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
    response = _fetch(
        context, url, 8 * 1024 * 1024, route,
        extra_headers={"Accept-Language": "zh-CN,zh;q=0.9"},
    )
    if not response.get("ok"):
        raise RuntimeError(f"获取文件夹内容失败: {response.get('error') or '未知错误'}")
    body = response.get("body") or ""
    if is_denied_page(body):
        raise RuntimeError("该文件夹可能未公开分享，或链接已失效")
    response_date = header_value(response.get("headers") or {}, "date")
    try:
        reference_year = email.utils.parsedate_to_datetime(response_date).year
    except (TypeError, ValueError, IndexError):
        reference_year = datetime.datetime.now().year
    items = parse_folder_page(body, reference_year)
    title_match = re.search(r"<title>([^<]*)</title>", body, re.IGNORECASE)
    folder_name = html.unescape(title_match.group(1)).strip() if title_match else ""
    return items, folder_name


def _list_folder_items(
    context: Any,
    folder_id: str,
    route: str,
    page_size: int = _PAGE_SIZE,
    max_pages: int = 50,
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
                context.check_cancelled()
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

    return items, folder_name


def _probe_item_sizes(
    context: Any,
    items: list[dict[str, object]],
    route: str,
) -> None:
    """仅处理显式选择的一批文件；失败保持原大小，不影响目录解析。"""
    files = [
        item for item in items
        if item.get("type") == "file" and int(item.get("sizeBytes") or 0) <= 0
    ]
    if not files:
        return
    with concurrent.futures.ThreadPoolExecutor(max_workers=_MAX_WORKERS) as executor:

        def _one(item: dict[str, object]) -> int:
            return _probe_file_size(context, str(item.get("id") or ""), route)

        results = list(executor.map(_one, files))
    for item, size_bytes in zip(files, results):
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
    parent_path = _parent_path(params).rstrip("/")

    context.progress(0.05, "正在获取文件夹内容")

    # 目录导航只等待目录页本身。页面已有的大小信息直接使用；逐文件 Range
    # 探测会让每次双击都等待整批网络请求，且不影响下载直链的生成。
    items, folder_name = _cached_folder_items(
        context, folder_id, route, refresh=bool(params.get("forceRefresh")),
    )

    total = len(items)
    total_bytes = 0
    for index, item in enumerate(items):
        context.check_cancelled()
        item["path"] = f"{parent_path}/{folder_name}" if folder_name else (parent_path or "/")
        if item.get("type") == "file":
            file_id = str(item.get("id") or "")
            item["downloadUrl"] = direct_download_url(file_id)
            size_bytes = int(item.get("sizeBytes") or 0)
            total_bytes += size_bytes
        if index == total - 1 or index % max(1, total // 10) == 0:
            context.progress(
                0.1 + 0.85 * (index + 1) / total,
                f"正在读取文件信息 {index + 1}/{total}",
            )

    context.progress(1.0, "解析完成")

    return {"folderId": folder_id, "folderName": folder_name, "items": items, "totalSize": total_bytes}


class _Budget:
    def __init__(self, limit: int) -> None:
        self.remaining = limit


def _collect_tree(
    context: Any,
    folder_id: str,
    route: str,
    budget: _Budget,
    path: str = "/",
    refresh: bool = False,
) -> dict[str, Any]:
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
        "_loaded": False,
    }
    node_by_id: dict[str, dict[str, Any]] = {folder_id: root_node}
    pending: list[dict[str, Any]] = [root_node]
    completed_folders = 0
    discovered_folders = 1

    def report_progress() -> None:
        context.progress(
            0.05 + 0.9 * completed_folders / (discovered_folders + 1),
            f"已解析 {completed_folders} / 已发现 {discovered_folders} 个目录",
            {"completedFolders": completed_folders,
             "discoveredFolders": discovered_folders},
        )

    report_progress()

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
                    items, folder_name = _cached_folder_items(
                        context, nid, route, refresh=refresh,
                    )
                    if folder_name:
                        node["name"] = folder_name
                    return node, items
                except Exception as error:
                    context.check_cancelled()
                    if node is root_node:
                        raise
                    context.log(f"解析文件夹失败 {node.get('name') or nid}: {error}")
                    return node, []

            futures = {executor.submit(_load, node): node for node in batch}
            for future, node in futures.items():
                context.check_cancelled()
                nid = str(node.get("id") or "")
                node["children"] = []
                loaded_node, items = future.result()
                context.check_cancelled()
                current_path = node.get("path") or path
                if loaded_node.get("name"):
                    current_path = f"{current_path}/{loaded_node['name']}"
                if budget.remaining <= 0:
                    continue
                node["_loaded"] = True
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
                        item["_loaded"] = False
                        if child_id in node_by_id:
                            item["_reused"] = True
                        else:
                            node_by_id[child_id] = item
                            pending.append(item)
                            discovered_folders += 1
                        node["children"].append(item)
                    else:
                        item["children"] = []
                        item["depth"] = int(node.get("depth") or 0) + 1
                        file_id = str(item.get("id") or "")
                        item["downloadUrl"] = direct_download_url(file_id)
                        node["children"].append(item)
                completed_folders += 1
                if completed_folders % _MAX_WORKERS == 0 or completed_folders == discovered_folders:
                    report_progress()

    return root_node


def list_folder_tree(context: Any, params: dict[str, Any]) -> dict[str, Any]:
    context.check_cancelled()
    url = str(params.get("url") or "").strip()
    route = str(params.get("route") or "auto").strip() or "auto"

    folder_id = folder_id_from_url(url)
    if not folder_id:
        raise ValueError("无法识别谷歌网盘文件夹链接，请粘贴分享链接")

    context.progress(0.05, "正在获取完整目录树")

    budget = _Budget(_MAX_TREE_ITEMS)
    root_node = _collect_tree(
        context, folder_id, route, budget, path=_parent_path(params),
        refresh=bool(params.get("forceRefresh")),
    )
    tree = root_node.get("children") or []
    total_files = 0
    total_bytes = 0
    incomplete = False

    def _count(nodes: list[dict[str, Any]]) -> None:
        nonlocal total_files, total_bytes, incomplete
        for node in nodes:
            if node.get("type") == "folder":
                if not node.get("_loaded") and not node.get("_reused"):
                    incomplete = True
                _count(node.get("children") or [])
            else:
                total_files += 1
                total_bytes += int(node.get("sizeBytes") or 0)

    _count(tree)
    context.progress(1.0, "目录树解析完成")

    return {
        "folderId": folder_id,
        "folderName": str(root_node.get("name") or ""),
        "tree": tree,
        "totalFiles": total_files,
        "totalSize": total_bytes,
        "truncated": budget.remaining <= 0 or incomplete,
    }
