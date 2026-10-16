"""Navigation and explicit reading coverage for stored, untrusted web content."""
import re

TOPICS = {
    'team': (r'团队|團隊|創辦|创始|创办|聯絡人|联系人|team|founder|leadership',
             r'team|people|leadership|founder|business.{0,8}operation|团队|團隊|创始|創辦|管理层'),
    'product': (r'业务|業務|产品|產品|服務|服务|product|business',
                r'product|solution|service|业务|業務|产品|產品|服務|服务'),
    'news': (r'近期|最近|最新|动态|新闻|news|recent|latest',
             r'news|press|award|recognition|milestone|动态|新闻|獎項|奖项'),
}


def navigation(text):
    """Offsets refer to the exact stored markdown, never normalized text."""
    sections = [];seen=set()
    for match in re.finditer(r'(?m)^([^\n]{1,180})$', text):
        line = match[1].strip()
        heading=bool(re.match(r'^#{1,6}\s+',line))
        label=(len(line)<=100 and len(line.split())<=10 and not line.endswith(('.', '。','!','！','?','？'))
               and any(re.search(p[1],line,re.I) for p in TOPICS.values()))
        if not (heading or label):continue
        title = re.sub(r'^#{1,6}\s+', '', line)
        if title.startswith(('![', '[!')) or title.casefold() in seen:continue
        seen.add(title.casefold());sections.append({'title':title,'offset':match.start()})
    # Prefer genuine topic headings to repeated navigation/footer labels. Keep
    # unrelated headings distributed, so the final chapters remain discoverable.
    if len(sections)>48:
        relevant=[s for s in sections if any(re.search(p[1],s['title'],re.I) for p in TOPICS.values())]
        keep=relevant[:24]
        rest=[s for s in sections if s not in keep]
        count=48-len(keep)
        keep.extend(rest[round(i*(len(rest)-1)/(count-1))] for i in range(count))
        sections=sorted(keep,key=lambda s:s['offset'])
    return sections


def reading_metadata(text, end=2200):
    return {'total_chars': len(text), 'offset': 0, 'end_offset': min(end, len(text)),
            'next_offset': end if len(text) > end else None,
            'sections': navigation(text),
            'coverage_note': '仅已返回的字符范围已读；目录不是正文，也不代表全文已读。'}


def unread_sections(sources, query):
    """Required topic sections absent from actual returned ranges, per version."""
    needed = []
    for item in sources:
        if item.get('reading_range') not in {'page_excerpt', 'source_excerpt'} or not item.get('source_id','').startswith('research:'):continue
        ranges = [(s.get('offset',0), s.get('end_offset',len(s.get('text','')))) for s in sources
                  if s['source_id']==item['source_id'] and s['source_version']==item['source_version']]
        merged=[]
        for start,end in sorted(ranges):
            if merged and start<=merged[-1][1]:merged[-1]=(merged[-1][0],max(end,merged[-1][1]))
            else:merged.append((start,end))
        ranges=merged
        for section in item.get('sections',[]):
            if not any(re.search(prompt,query,re.I) and re.search(heading,section['title'],re.I)
                       for prompt,heading in TOPICS.values()):continue
            offset=section['offset']
            # A heading alone at the end of an excerpt doesn't cover its body.
            required_end=min(offset+1200,item.get('total_chars',offset+1200))
            if any(start<=offset and end>=required_end for start,end in ranges):continue
            key=(item['source_id'],offset)
            if not any((x['source_id'],x['offset'])==key for x in needed):
                needed.append({'source_id':key[0],'offset':offset,'title':section['title']})
    return needed
