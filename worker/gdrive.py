from __future__ import annotations

import html
import re
from typing import Any, Dict, List, Optional, Tuple
from urllib.parse import unquote

DOWNLOAD_BASE = "https://drive.usercontent.google.com/download"

_FILE_ID_PATTERNS = [
    re.compile(r"/file/d/([^/?#&]+)"),
    re.compile(r"[?&]id=([^&?#]+)"),
    re.compile(r"/d/([^/?#&]+)"),
]

_FOLDER_ID_PATTERNS = [
    re.compile(r"/drive/folders/([^/?#&]+)"),
    re.compile(r"folder=([^&?#]+)"),
    re.compile(r"folderview\?id=([^&?#]+)"),
]


def file_id_from_url(url: str) -> str:
    for pattern in _FILE_ID_PATTERNS:
        match = pattern.search(url)
        if match:
            return match.group(1)
    return ""


def folder_id_from_url(url: str) -> str:
    for pattern in _FOLDER_ID_PATTERNS:
        match = pattern.search(url)
        if match:
            return match.group(1)
    return ""


def header_value(headers: object, name: str) -> str:
    for key, value in (headers or {}).items():
        if str(key).lower() == name.lower():
            return str(value)
    return ""


def extract_confirm_token(body: str) -> str:
    pairs = re.findall(r'name="([^"]+)" value="([^"]*)"', body)
    for field_name, field_value in pairs:
        if field_name == "confirm":
            return field_value
    pairs = re.findall(r'value="([^"]*)" name="([^"]+)"', body)
    for field_value, field_name in pairs:
        if field_name == "confirm":
            return field_value
    pairs = re.findall(r"name='([^']+)' value='([^']*)'", body)
    for field_name, field_value in pairs:
        if field_name == "confirm":
            return field_value
    return ""


def extract_download_action(body: str) -> str:
    match = re.search(r'<form[^>]+action="([^"]+)"', body, re.IGNORECASE)
    if match:
        return match.group(1)
    return ""


def filename_from_disposition(value: str) -> str:
    match = re.search(r"filename\*=(?:UTF-8|utf-8)''([^;]+)", value, re.IGNORECASE)
    if match:
        candidate = match.group(1).strip().strip('"')
        if candidate:
            try:
                return unquote(candidate)
            except Exception:
                return candidate
    match = re.search(r'filename="([^"]+)"', value, re.IGNORECASE)
    if match:
        return match.group(1).strip()
    match = re.search(r"filename=([^;]+)", value, re.IGNORECASE)
    if match:
        return match.group(1).strip().strip('"')
    return ""


def filename_from_html(body: str) -> str:
    match = re.search(r"<title>([^<]*)</title>", body, re.IGNORECASE)
    if not match:
        return ""
    title = html.unescape(match.group(1)).strip()
    marker = "Virus scan warning for "
    if marker in title:
        return title.split(marker, 1)[1].strip()
    return ""


def is_denied_page(body: str) -> bool:
    lowered = body[:6000].lower()
    signals = (
        "you can't view or download this file",
        "you do not have permission",
        "this file may not have the correct",
        "no preview available",
        "error 404",
        "an error occurred during processing",
    )
    return any(signal in lowered for signal in signals)


def build_download_info(
    file_id: str,
    final_url: str,
    body: str,
    content_disposition: str,
) -> Tuple[str, str]:
    if "drive.usercontent.google.com" in (final_url or ""):
        return final_url, filename_from_disposition(content_disposition)

    if (body or "").lstrip().startswith("<"):
        action = extract_download_action(body)
        confirm = extract_confirm_token(body)
        base = action if action.startswith("https://") else DOWNLOAD_BASE
        sep = "&" if "?" in base else "?"
        url = f"{base}{sep}id={file_id}&export=download"
        if confirm:
            url += f"&confirm={confirm}"
        return url, filename_from_html(body)

    url = f"{DOWNLOAD_BASE}?id={file_id}&export=download"
    return url, filename_from_disposition(content_disposition)


_ENTRY_RE = re.compile(
    r'<div class="flip-entry" id="entry-([^"]+)"[^>]*>'
    r'.*?<a href="(https://drive\.google\.com/(?:file/d/|drive/folders/)[^"]+)"[^>]*>'
    r'.*?<div class="flip-entry-title">([^<]*)</div>',
    re.IGNORECASE | re.DOTALL,
)

_FOLDER_HREF_RE = re.compile(r"drive\.google\.com/drive/folders/([-\w]+)")
_FILE_HREF_RE = re.compile(r"drive\.google\.com/file/d/([-\w]+)")
_LINK_ID_RE = re.compile(r"[?&]id=([-\w]+)")


def parse_folder_page(body: str) -> List[Dict[str, str]]:
    folder_name = ""
    title_match = re.search(r"<title>([^<]*)</title>", body, re.IGNORECASE)
    if title_match:
        folder_name = html.unescape(title_match.group(1)).strip()

    items: List[Dict[str, str]] = []
    for entry_match in _ENTRY_RE.finditer(body):
        entry_id = entry_match.group(1)
        href = entry_match.group(2)
        name = html.unescape(entry_match.group(3)).strip()
        if not name:
            continue

        folder_match = _FOLDER_HREF_RE.search(href)
        file_match = _FILE_HREF_RE.search(href)
        if folder_match:
            items.append({
                "name": name,
                "id": folder_match.group(1),
                "type": "folder",
                "size": "",
            })
        elif file_match:
            items.append({
                "name": name,
                "id": file_match.group(1),
                "type": "file",
                "size": "",
            })

    return items


def format_size(size_bytes: object) -> str:
    try:
        size = int(size_bytes or 0)
    except (TypeError, ValueError):
        return ""
    if size <= 0:
        return ""
    units = ("B", "KB", "MB", "GB", "TB")
    value = float(size)
    for unit in units:
        if value < 1024.0 or unit == units[-1]:
            if unit == "B":
                return f"{int(value)} B"
            return f"{value:.1f} {unit}"
        value /= 1024.0
    return ""