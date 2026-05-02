import logging
from typing import Optional

import requests
from open_webui.retrieval.web.main import SearchResult, get_filtered_results

log = logging.getLogger(__name__)

TAVILY_MAX_QUERY_LENGTH = 400


def search_tavily(
    api_key: str,
    query: str,
    count: int,
    filter_list: Optional[list[str]] = None,
) -> list[SearchResult]:
    query = (query or '').strip()
    if not query:
        log.warning("search_tavily: empty query, skipping")
        return []
    if len(query) > TAVILY_MAX_QUERY_LENGTH:
        log.warning(
            "search_tavily: query length %d exceeds Tavily's %d-char limit, truncating",
            len(query),
            TAVILY_MAX_QUERY_LENGTH,
        )
        query = query[:TAVILY_MAX_QUERY_LENGTH]

    url = 'https://api.tavily.com/search'
    headers = {
        'Content-Type': 'application/json',
        'Authorization': f'Bearer {api_key}',
    }
    data = {'query': query, 'max_results': count}
    response = requests.post(url, headers=headers, json=data)
    response.raise_for_status()

    json_response = response.json()

    results = json_response.get('results', [])
    if filter_list:
        results = get_filtered_results(results, filter_list)

    return [
        SearchResult(
            link=result['url'],
            title=result.get('title', ''),
            snippet=result.get('content'),
        )
        for result in results
    ]
