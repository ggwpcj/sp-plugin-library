from __future__ import annotations

import html
import re
from datetime import date
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


_ENTRY_BOUNDARY = re.compile(
    r'<div class="flip-entry" id="entry-([^"]+)"',
    re.IGNORECASE,
)

_ENTRY_HREF_RE = re.compile(
    r'<a[^>]+href="(https://drive\.google\.com/(?:file/d/|drive/folders/)[^"]+)"',
    re.IGNORECASE,
)

_ENTRY_TITLE_RE = re.compile(
    r'<div class="flip-entry-title"[^>]*>(.*?)</div>',
    re.IGNORECASE | re.DOTALL,
)

_SIZE_DIV_RE = re.compile(
    r'<div class="flip-entry-size"[^>]*>(.*?)</div>',
    re.IGNORECASE | re.DOTALL,
)

_LAST_MODIFIED_RE = re.compile(
    r'<div class="flip-entry-last-modified"[^>]*>(.*?)</div>',
    re.IGNORECASE | re.DOTALL,
)

_MONTH_DAY_ZH_RE = re.compile(r"^(\d{1,2})月(\d{1,2})日$")
_MONTH_DAY_EN_RE = re.compile(
    r"^(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\s+(\d{1,2})$",
    re.IGNORECASE,
)
_EN_MONTHS = {name.lower(): index for index, name in enumerate(
    ("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"), 1
)}

_FOLDER_HREF_RE = re.compile(r"drive\.google\.com/drive/folders/([-\w]+)")
_FILE_HREF_RE = re.compile(r"drive\.google\.com/file/d/([-\w]+)")
_LINK_ID_RE = re.compile(r"[?&]id=([-\w]+)")

_SIZE_UNITS = {"K": 1024, "M": 1024**2, "G": 1024**3, "T": 1024**4}


def display_modified_date(value: str, reference_year: int) -> str:
    """Expand Drive's yearless current-year display using its response year."""
    text = str(value or "").strip()
    chinese = _MONTH_DAY_ZH_RE.fullmatch(text)
    english = _MONTH_DAY_EN_RE.fullmatch(text) if not chinese else None
    if not chinese and not english:
        return text
    month = int(chinese.group(1)) if chinese else _EN_MONTHS[english.group(1).lower()]
    day = int(chinese.group(2) if chinese else english.group(2))
    try:
        date(reference_year, month, day)
    except ValueError:
        return text
    return f"{reference_year}/{month}/{day}"


def parse_size_text(text: str) -> int:
    if not text:
        return 0
    match = re.search(r"([\d.]+)\s*([KkMmGgTt]?)[Bb]?", (text or "").replace(",", ""))
    if not match:
        return 0
    try:
        value = float(match.group(1))
    except ValueError:
        return 0
    unit = match.group(2).upper() or ""
    mult = _SIZE_UNITS.get(unit, 1)
    return int(value * mult)


def _entry_blocks(body: str) -> List[Tuple[str, str]]:
    bounds = list(_ENTRY_BOUNDARY.finditer(body))
    blocks: List[Tuple[str, str]] = []
    for index, match in enumerate(bounds):
        block_end = bounds[index + 1].start() if index + 1 < len(bounds) else len(body)
        blocks.append((match.group(1), body[match.start():block_end]))
    return blocks


def parse_folder_page(body: str, reference_year: int = 0) -> List[Dict[str, object]]:
    folder_name = ""
    title_match = re.search(r"<title>([^<]*)</title>", body, re.IGNORECASE)
    if title_match:
        folder_name = html.unescape(title_match.group(1)).strip()

    items: List[Dict[str, object]] = []
    for _entry_id, block in _entry_blocks(body):
        href_match = _ENTRY_HREF_RE.search(block)
        if not href_match:
            continue
        title_match = _ENTRY_TITLE_RE.search(block)
        name = html.unescape(title_match.group(1)).strip() if title_match else ""
        if not name:
            continue

        size_text = ""
        size_match = _SIZE_DIV_RE.search(block)
        if size_match:
            size_text = html.unescape(size_match.group(1)).strip()
        size_bytes = parse_size_text(size_text)
        modified_match = _LAST_MODIFIED_RE.search(block)
        modified_text = (
            html.unescape(re.sub(r"<[^>]+>", "", modified_match.group(1))).strip()
            if modified_match else ""
        )
        if reference_year:
            modified_text = display_modified_date(modified_text, reference_year)

        folder_match = _FOLDER_HREF_RE.search(href_match.group(1))
        file_match = _FILE_HREF_RE.search(href_match.group(1))
        if folder_match:
            items.append({
                "name": name,
                "id": folder_match.group(1),
                "type": "folder",
                "size": size_text,
                "sizeBytes": size_bytes,
                "modifiedDisplay": modified_text,
            })
        elif file_match:
            items.append({
                "name": name,
                "id": file_match.group(1),
                "type": "file",
                "size": size_text,
                "sizeBytes": size_bytes,
                "modifiedDisplay": modified_text,
            })

    return items


_CONTENT_RANGE_BYTES_RE = re.compile(r"bytes\s+\d+-\d+\s*/\s*(\d+)", re.IGNORECASE)


def parse_size_from_content_range(value: str) -> int:
    """从 `Content-Range: bytes 0-0/<total>` 或 `bytes */<total>` 提取总大小。

    谷歌网盘下载直链对公开文件支持 Range 请求（206），且不受大文件
    病毒确认页影响；返回 1 字节与该头部即可拿到文件真实大小。
    """
    if not value:
        return 0
    match = _CONTENT_RANGE_BYTES_RE.search(str(value))
    if not match:
        return 0
    try:
        return int(match.group(1))
    except (TypeError, ValueError):
        return 0


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
