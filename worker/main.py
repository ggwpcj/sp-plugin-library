from __future__ import annotations

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


def _probe_file(context: Any, file_id: str, route: str = "auto") -> tuple[str, str, str]:
    response = _fetch(
        context,
        f"https://drive.google.com/uc?export=download&id={file_id}",
        512 * 1024,
        route,
    )

    if not response.get("ok"):
        final_url = response.get("url") or ""
        if "drive.usercontent.google.com" in final_url:
            return final_url, "", final_url
        raise RuntimeError(response.get("error") or "请求失败")

    final_url = response.get("url") or ""
    body = response.get("body") or ""
    headers = response.get("headers") or {}
    content_disposition = header_value(headers, "content-disposition")

    size_display = ""
    if "drive.usercontent.google.com" in (final_url or ""):
        content_length = header_value(headers, "content-length")
        size_display = format_size(content_length)
        return final_url, size_display, final_url

    if (body or "").lstrip().startswith("<"):
        action = extract_download_action(body)
        confirm = extract_confirm_token(body)
        base = action if action.startswith("https://") else "https://drive.usercontent.google.com/download"
        sep = "&" if "?" in base else "?"
        direct_url = f"{base}{sep}id={file_id}&export=download"
        if confirm:
            direct_url += f"&confirm={confirm}"
        return direct_url, "", direct_url

    return final_url or f"https://drive.google.com/uc?export=download&id={file_id}", \
        size_display, final_url or f"https://drive.google.com/uc?export=download&id={file_id}"


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

    total = len(items)
    for index, item in enumerate(items):
        context.check_cancelled()
        if item.get("type") == "file":
            item["downloadUrl"] = ""
            try:
                download_url, size_display, resolved_url = _probe_file(context, item["id"], route)
                item["downloadUrl"] = download_url
                item["size"] = size_display
            except Exception as error:
                item["size"] = ""
                context.log(f"获取文件信息失败对 {item.get('name')}: {error}")
        context.progress(
            0.1 + 0.85 * (index + 1) / total,
            f"正在获取文件信息 {index + 1}/{total}",
        )

    context.progress(1.0, "解析完成")

    return {"folderId": folder_id, "items": items}