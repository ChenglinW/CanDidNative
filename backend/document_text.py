"""Shared PDF text intake; preserve pages and distinguish unreadable documents."""
import io
from pypdf import PdfReader
from memory import Fault


def pdf_text(raw, max_pages=300, max_characters=200000):
    # Some exporters leave a UTF-8 BOM or whitespace before the PDF header.
    if not raw or raw.find(b'%PDF-', 0, 1024) < 0:
        raise Fault('PDF_INVALID', '文件不是有效 PDF，请重新导出后再试', 422)
    try:
        reader = PdfReader(io.BytesIO(raw))
        # Permission-encrypted PDFs can be opened with an empty user password.
        # is_encrypted remains True after decryption; it is not a readability test.
        if reader.is_encrypted and not reader.decrypt(''):
            raise Fault('PDF_PASSWORD_REQUIRED', 'PDF 需要打开密码，请先解除密码后重新上传', 422)
        if len(reader.pages) > max_pages:
            raise Fault('PDF_TOO_MANY_PAGES', f'PDF 超过 {max_pages} 页，请拆分后上传', 422)
        pages = []
        total = 0
        for number, page in enumerate(reader.pages, 1):
            text = page.extract_text() or ''
            total += len(text)
            if total > max_characters:
                raise Fault('PDF_TOO_MUCH_TEXT', 'PDF 文字超过 20 万字符，请拆分后上传', 422)
            pages.append({'page': number, 'text': text})
        if not any(page['text'].strip() for page in pages):
            raise Fault('PDF_NO_TEXT', 'PDF 没有可提取文字，可能是扫描件；请上传可选中文字的 PDF 或粘贴原文', 422)
        return '\n\n'.join('[第'+str(page['page'])+'页]\n'+page['text'] for page in pages), pages
    except Fault:
        raise
    except Exception:
        raise Fault('PDF_INVALID', 'PDF 损坏或无法解析，请重新导出后再试', 422) from None
