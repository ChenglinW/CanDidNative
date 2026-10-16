"""Deterministic publication time semantics; fetch time is never news time."""
import re
import calendar
from datetime import date,datetime,timedelta
from zoneinfo import ZoneInfo


def window(query='',as_of=None):
    today=as_of or datetime.now(ZoneInfo('Asia/Hong_Kong')).date()
    days=90
    match=re.search(r'(?:最近|近|过去)([一二三六两\d]+)(天|周|个月|月|年)',query)
    if match:
        amount={'一':1,'二':2,'两':2,'三':3,'六':6}.get(match[1])
        if amount is None:
            try:amount=int(match[1])
            except ValueError:amount=1
        days=amount*{'天':1,'周':7,'个月':30,'月':30,'年':365}[match[2]]
    return {'as_of':today.isoformat(),'recent_since':(today-timedelta(days=days)).isoformat(),
            'window_days':days,'timezone':'Asia/Hong_Kong',
            'rule':'近期仅包含该窗口内有可核实发布日期或事件日期的消息；抓取日期不是发布日期。历史、未来和日期未知分别列出，不用旧报道证明现任团队或已上线功能。'}


def parse_day(value):
    if not isinstance(value,str):return None
    match=re.match(r'^\s*(\d{4})[-/年](\d{1,2})[-/月](\d{1,2})(?:日|\b|T)',value)
    if not match:return None
    try:return date(*map(int,match.groups()))
    except ValueError:return None


def publication(text,metadata=None):
    metadata=metadata or {}
    text=text if isinstance(text,str) else ''
    for key in ('publishedTime','publishedDate','datePublished','article:published_time','published_at','published_date'):
        if parse_day(metadata.get(key)):
            return {'published_at':metadata[key],'publication_date_basis':'provider_metadata:'+key}
    # Only an explicit dateline, not arbitrary dates mentioned in article text.
    match=re.search(r'(?:Published(?:\s+on)?|發布(?:日期|時間)?|发布(?:日期|时间)?|刊登日期|日期)\s*[:：]?\s*(\d{4}[-/年]\d{1,2}[-/月]\d{1,2}日?)',text[:2000],re.I)
    if match and parse_day(match[1]):return {'published_at':match[1],'publication_date_basis':'visible_publication_dateline'}
    return {}


def classify(value,context):
    day=parse_day(value)
    low=high=day
    if day is None and isinstance(value,str):
        partial=re.fullmatch(r'\s*(\d{4})(?:[-/年](\d{1,2})月?)?年?\s*',value)
        if partial:
            try:
                year=int(partial[1]);month=int(partial[2]) if partial[2] else None
                low=date(year,month or 1,1)
                high=date(year,month,calendar.monthrange(year,month)[1]) if month else date(year,12,31)
            except (ValueError,calendar.IllegalMonthError):low=high=None
    if low is None:return {'classification':'unknown','note':'缺少可核实的发布日期；获取日期不能用于判断近期。'}
    today=date.fromisoformat(context['as_of']);since=date.fromisoformat(context['recent_since'])
    category='future' if low>today else 'historical' if high<since else 'recent' if low>=since and high<=today else 'unknown'
    return {'classification':category,'published_day':day.isoformat() if day else None,
            'date_range':[low.isoformat(),high.isoformat()],'as_of':context['as_of'],'recent_since':context['recent_since']}


def needs_recent(query):
    return bool(re.search(r'近期|最近|最新|动态|新闻|\brecent\b|\blatest\b',query,re.I))


def dated_news_violations(content,context):
    """Catch explicit old/future dates under a recent-news heading, not history."""
    bad=[];recent=False
    for line in content.splitlines():
        if re.match(r'^\s*(?:#{1,6}\s|\*\*[^*]+\*\*\s*$|[一二三四五六七八九十]+[、.]|\d{1,2}[、.)]\s)',line):
            recent=bool(re.search(r'近期|最近|最新|recent|latest',line,re.I)) and not bool(re.search(r'历史|歷史|historical',line,re.I))
        if not recent or re.search(r'历史|歷史|非近期|不属于近期|未找到|未发现|暂无|无可核实|historical|no recent',line,re.I):continue
        for match in re.finditer(r'(?<!\d)20\d{2}(?:[-/年]\d{1,2}(?:[-/月]\d{1,2}日?)?月?)?年?(?!\d)',line):
            if classify(match[0],context)['classification'] in {'historical','future'}:bad.append(match[0])
    return sorted(set(bad))
