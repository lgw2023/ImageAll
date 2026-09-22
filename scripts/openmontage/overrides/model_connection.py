"""App-configured OpenAI-compatible model connection; never discovers shell secrets."""
import json
import math
import os
from urllib.parse import urlsplit, urlunsplit

import httpx
from openai import OpenAI

KEY_ENV = 'OPENMONTAGE_MODEL_API_KEY'
RESERVED = {'model', 'messages', 'stream', 'temperature', 'max_tokens', 'max_completion_tokens',
            'response_format', 'api_key', 'apiKey', 'headers', 'authorization', 'base_url'}


def normalize_url(value):
    parsed = urlsplit(value.strip().rstrip('/'))
    if (not parsed.hostname or parsed.username or parsed.password or parsed.query or parsed.fragment
            or not (parsed.scheme == 'https' or parsed.scheme == 'http' and parsed.hostname in ('localhost', '127.0.0.1', '::1'))):
        raise ValueError('Model endpoint requires HTTPS, or HTTP on loopback, without credentials/query/fragment')
    path = parsed.path.rstrip('/')
    if path.endswith('/chat/completions'):
        path = path[:-len('/chat/completions')]
    base = urlunsplit((parsed.scheme, parsed.netloc, path, '', ''))
    return base, base + '/chat/completions'


def load_connection():
    filename = os.environ.get('OPENMONTAGE_CONFIG_PATH')
    if not filename:
        raise ValueError('Configure the model connection in ImageAll settings first')
    with open(filename) as handle:
        value = json.load(handle).get('connection')
    if not isinstance(value, dict):
        raise ValueError('Model connection is not configured')
    config = dict(value)
    config['baseURL'], config['endpoint'] = normalize_url(config.get('baseURL', ''))
    if not isinstance(config.get('model'), str) or not config['model'].strip():
        raise ValueError('Model name is required')
    for key, low, high in [('temperature', 0, 2), ('timeoutSeconds', 1, 600), ('maxTokens', 1, 1000000)]:
        n = config.get(key)
        if isinstance(n, bool) or not isinstance(n, (int, float)) or not math.isfinite(n) or not low <= n <= high:
            raise ValueError('Invalid model parameter: ' + key)
    if not isinstance(config['maxTokens'], int) or config.get('responseFormat') not in ('json_object', 'text') or config.get('tokenParameter') not in ('max_tokens', 'max_completion_tokens'):
        raise ValueError('Invalid model protocol parameters')
    extra = json.loads(config.get('extraBody', '{}'))
    if not isinstance(extra, dict) or RESERVED.intersection(extra):
        raise ValueError('Extra body cannot override core request fields or contain credentials')
    config['extra'] = extra
    for field in ('organization', 'project'):
        if not isinstance(config.get(field, ''), str) or '\n' in config.get(field, '') or '\r' in config.get(field, ''):
            raise ValueError('Invalid SDK header setting')
    return config


def complete(config, messages, key):
    # Explicit endpoint, no automatic retries, no redirect of private photos or credentials.
    with httpx.Client(follow_redirects=False, timeout=config['timeoutSeconds']) as transport:
        with OpenAI(api_key=key, base_url=config['baseURL'], timeout=config['timeoutSeconds'], max_retries=0,
                    organization=config.get('organization') or None, project=config.get('project') or None,
                    http_client=transport) as client:
            parameters = dict(model=config['model'], messages=messages, temperature=config['temperature'],
                              extra_body=config['extra'], **{config['tokenParameter']: config['maxTokens']})
            if config['responseFormat'] == 'json_object':
                parameters['response_format'] = {'type': 'json_object'}
            return client.chat.completions.create(**parameters).model_dump()
