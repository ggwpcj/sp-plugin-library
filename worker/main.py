from __future__ import annotations

import html
import re
from typing import Any

from .gdrive import (
    build_download_info,
    extract_confirm_token,
    extract_download_action,
    file_id_from_url,
    folder_id_from_url,
    format_size,
    header_value,
    is_denied_page,
    parse_folder_page,
)

_MAX_TREE_DEPTH = 100
_MAX_TREE_ITEMS = 5000

_USER_AGENT = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
    "AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/124.0.0.0 Safari/537.36"
)


def _fetch(context: Any, url: str, max_bytes: int, route: str = "auto") -> dict[str, Any]:
    return context.request({
        "url": url,
        "method": "GET",
        "route": route,
        "timeoutMs": 20000,
        "maxBytes": max_bytes,
        "headers": {
            "User-Agent": _USER_AGENT,
            "Accept-Encoding": "identity",
        },
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


def _probe_file(context: Any, file_id: str, route: str = "auto") -> tuple[str, str, str, int]:
    response = _fetch(
        context,
        f"https://drive.google.com/uc?export=download&id={file_id}",
        512 * 1024,
        route,
    )

    if not response.get("ok"):
        final_url = response.get("url") or ""
        if "drive.usercontent.google.com" in final_url:
            return final_url, "", final_url, 0
        raise RuntimeError(response.get("error") or "请求失败")

    final_url = response.get("url") or ""
    body = response.get("body") or ""
    headers = response.get("headers") or {}
    content_disposition = header_value(headers, "content-disposition")

    size_display = ""
    size_bytes = 0
    if "drive.usercontent.google.com" in (final_url or ""):
        content_length = header_value(headers, "content-length")
        try:
            size_bytes = int(content_length or 0)
        except (TypeError, ValueError):
            size_bytes = 0
        size_display = format_size(size_bytes)
        return final_url, size_display, final_url, size_bytes

    if (body or "").lstrip().startswith("<"):
        action = extract_download_action(body)
        confirm = extract_confirm_token(body)
        base = action if action.startswith("https://") else "https://drive.usercontent.google.com/download"
        sep = "&" if "?" in base else "?"
        direct_url = f"{base}{sep}id={file_id}&export=download"
        if confirm:
            direct_url += f"&confirm={confirm}"
        return direct_url, "", direct_url, 0

    return final_url or f"https://drive.google.com/uc?export=download&id={file_id}", \
        size_display, final_url or f"https://drive.google.com/uc?export=download&id={file_id}", 0


def list_folder(context: Any, params: dict[str, Any]) -> dict[str, Any]:
    context.check_cancelled()
    url = str(params.get("url") or "").strip()
    route = str(params.get("route") or "auto").strip() or "auto"

    folder_id = folder_id_from_url(url)
    if not folder_id:
        raise ValueError("无法识别谷歌网盘文件夹链接，请粘贴分享链接")

    context.progress(0.05, "正在获取文件夹内容")

    response = _fetch(
        context,
        f"https://drive.google.com/embeddedfolderview?id={folder_id}",
        8 * 1024 * 1024,
        route,
    )

    if not response.get("ok"):
        raise RuntimeError(f"获取文件夹内容失败: {response.get('error') or '未知错误'}")

    body = response.get("body") or ""
    if is_denied_page(body):
        raise RuntimeError("该文件夹可能未公开分享，或链接已失效")

    items = parse_folder_page(body)
    if not items:
        raise RuntimeError("文件夹为空，或无法解析内容")

    folder_name = ""
    title_match = re.search(r"<title>([^<]*)</title>", body, re.IGNORECASE)
    if title_match:
        folder_name = html.unescape(title_match.group(1)).strip()

    total = len(items)
    total_bytes = 0
    for index, item in enumerate(items):
        context.check_cancelled()
        item["path"] = f"/{folder_name}" if folder_name else "/"
        if item.get("type") == "file":
            item["downloadUrl"] = ""
            try:
                download_url, size_display, resolved_url, size_bytes = _probe_file(context, item["id"], route)
                item["downloadUrl"] = download_url
                item["size"] = size_display
                item["sizeBytes"] = size_bytes
                total_bytes += size_bytes
            except Exception as error:
                item["size"] = ""
                item["sizeBytes"] = 0
                context.log(f"获取文件信息失败对 {item.get('name')}: {error}")
        context.progress(
            0.1 + 0.85 * (index + 1) / total,
            f"正在获取文件信息 {index + 1}/{total}",
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
    depth: int,
    budget: _Budget,
    path: str = "/",
) -> list[dict[str, Any]]:
    if depth > _MAX_TREE_DEPTH:
        context.log(f"目录层级超过上限 {_MAX_TREE_DEPTH}，已截断")
        return []
    if budget.remaining <= 0:
        return []

    response = _fetch(
        context,
        f"https://drive.google.com/embeddedfolderview?id={folder_id}",
        8 * 1024 * 1024,
        route,
    )
    if not response.get("ok"):
        raise RuntimeError(f"获取文件夹内容失败: {response.get('error') or '未知错误'}")

    body = response.get("body") or ""
    if is_denied_page(body):
        raise RuntimeError("该文件夹可能未公开分享，或链接已失效")

    items = parse_folder_page(body)
    folder_name = ""
    title_match = re.search(r"<title>([^<]*)</title>", body, re.IGNORECASE)
    if title_match:
        folder_name = html.unescape(title_match.group(1)).strip()
    current_path = f"{path}/{folder_name}" if folder_name else path

    nodes: list[dict[str, Any]] = []
    for item in items:
        context.check_cancelled()
        if budget.remaining <= 0:
            context.log("目录内容过多，已达到上限，剩余目录已截断")
            break
        budget.remaining -= 1
        item["path"] = current_path
        if item.get("type") == "folder":
            item["downloadUrl"] = ""
            item["size"] = ""
            item["sizeBytes"] = 0
            item["children"] = _collect_tree(context, item["id"], route, depth + 1, budget, current_path)
            nodes.append(item)
        else:
            item["children"] = []
            item["downloadUrl"] = ""
            try:
                download_url, size_display, _resolved, size_bytes = _probe_file(context, item["id"], route)
                item["downloadUrl"] = download_url
                item["size"] = size_display
                item["sizeBytes"] = size_bytes
            except Exception as error:
                item["size"] = ""
                item["sizeBytes"] = 0
                context.log(f"获取文件信息失败对 {item.get('name')}: {error}")
            nodes.append(item)
    return nodes


def list_folder_tree(context: Any, params: dict[str, Any]) -> dict[str, Any]:
    context.check_cancelled()
    url = str(params.get("url") or "").strip()
    route = str(params.get("route") or "auto").strip() or "auto"

    folder_id = folder_id_from_url(url)
    if not folder_id:
        raise ValueError("无法识别谷歌网盘文件夹链接，请粘贴分享链接")

    context.progress(0.05, "正在获取完整目录树")

    budget = _Budget(_MAX_TREE_ITEMS)
    tree = _collect_tree(context, folder_id, route, 0, budget)
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