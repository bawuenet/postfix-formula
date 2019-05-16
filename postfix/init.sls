{% from "postfix/map.jinja" import postfix with context %}

postfix:
  pkg.installed:
    - name: {{ postfix.package }}
{%- if grains['os_family']=="FreeBSD" %}
    - force: True
    - batch: True
{%- endif %}
    - watch_in:
      - service: postfix
  service.running:
    - enable: {{ salt['pillar.get']('postfix:enable_service', True) }}
    - reload: {{ salt['pillar.get']('postfix:reload_service', True) }}
    - require:
      - pkg: postfix
    - watch:
      - pkg: postfix

{# Used for newaliases, postalias and postconf #}
{%- set default_database_type = salt['pillar.get']('postfix:config:default_database_type', 'hash') %}

# manage /etc/aliases if data found in pillar
{% if 'aliases' in pillar.get('postfix', '') %}
{% if salt['pillar.get']('postfix:aliases:use_file', true) == true %}
  {%- set need_newaliases = False %}
  {%- set file_path = postfix.aliases_file %}
  {%- if ':' in file_path %}
    {%- set file_type, file_path = postfix.aliases_file.split(':') %}
  {%- else %}
    {%- set file_type = default_database_type %}
  {%- endif %}
  {%- if file_type in ("btree", "cdb", "dbm", "hash", "sdbm") %}
    {%- set need_newaliases = True %}
  {%- endif %}
postfix_alias_database:
  file.managed:
    - name: {{ file_path }}
  {% if salt['pillar.get']('postfix:aliases:content', None) is string %}
    - contents_pillar: postfix:aliases:content
  {% else %}
    - source: salt://postfix/files/mapping.j2
  {% endif %}
    - user: root
    - group: {{ postfix.root_grp }}
    - mode: 644
    - template: jinja
    - context:
        data: {{ salt['pillar.get']('postfix:aliases:present') }}
        colon: True
    - require:
      - pkg: postfix
  {%- if need_newaliases %}
  cmd.wait:
    - name: newaliases
    - cwd: /
    - watch:
      - file: {{ file_path }}
  {%- endif %}
{% else %}
  {%- for user, target in salt['pillar.get']('postfix:aliases:present', {}).items() %}
postfix_alias_present_{{ user }}:
  alias.present:
    - name: {{ user }}
    - target: {{ target }}
  {%- endfor %}
  {%- for user in salt['pillar.get']('postfix:aliases:absent', {}) %}
postfix_alias_absent_{{ user }}:
  alias.absent:
    - name: {{ user }}
  {%- endfor %}
{% endif %}
{% endif %}

{%- macro map_file(mapping, file_path, data, restricted=False) %}
  {#- Lookup complete file with type spec from the config variable #}
  {% set path = [] %}
  {%- for item in salt['pillar.get']('postfix:config:{}'.format(mapping)) %}
    {%- if item.split(':') | last == file_path %}
      {%- do path.append(item) %}
      {%- break %}
    {%- endif %}
  {%- endfor %}
  {#- Sanity check #}
  {%- if path | length() < 1  %}
postfix_map_failure_{{ file_path | replace('/', '_') }}:
  test.fail_without_changes:
    - name: Did not find mapping {{ file_path }} referenced in postfix:config:{{ mapping }}.
    - failhard: True
  {%- else %}
  {%- set file_path = path | first %}
  {#- Special handling needed for the maps with a preceeding parameter,
  e.g. "check_recipient_access". Discard the prefix. #}
  {%- if ' ' in file_path %}
    {%- set file_path = file_path.split(' ', 1)[1] %}
  {%- endif %}
  {%- if file_path.startswith('proxy:') %}
    {#- Discard the proxy:-prefix #}
    {%- set _, file_type, file_path = file_path.split(':') %}
  {%- elif ':' in file_path %}
    {%- set file_type, file_path = file_path.split(':') %}
  {%- else %}
    {%- set file_type = default_database_type %}
  {%- endif %}
  {%- if not file_path.startswith('/') %}
    {%- set file_path = postfix.config_path ~ '/' ~ file_path %}
  {%- endif %}
  {%- if file_type in ("btree", "cdb", "dbm", "hash", "sdbm") %}
    {%- set need_postmap = True %}
  {%- else %}
    {%- set need_postmap = False %}
  {%- endif %}
postfix_{{ mapping }}_{{ file_path.split('/') | last }}:
  file.managed:
    - name: {{ file_path }}
    {%- if file_type in ("ldap", "memcache", "mysql", "nisplus", "pgsql", "sqlite") %}
    {%- set restricted = True %}{#- Map configurations usually contain passwords, set files to restricted #}
    - watch_in:
      - service: postfix
    - source: salt://postfix/files/mapping-cf.j2
    {%- else %}
    - source: salt://postfix/files/mapping.j2
    {%- endif %}
    - user: root
    - group: {{ postfix.root_grp }}
    {%- if mapping.endswith('_sasl_password_maps') or restricted %}
    - mode: 600
    {%- else %}
    - mode: 644
    {%- endif %}
    - template: jinja
    - context:
        data: {{ data|json() }}
    - require:
      - pkg: postfix
  {%- if need_postmap %}
  cmd.wait:
    - name: {{ postfix.xbin_prefix }}/sbin/postmap {{ file_path }}
    - cwd: /
    - watch:
      - file: {{ file_path }}
    - watch_in:
      - service: postfix
  {%- endif %}
  {%- endif %}
{%- endmacro %}

# manage various mappings
{%- for mapping, data in salt['pillar.get']('postfix:mapping', {}).items() %}
  {%- if data is mapping %}
    {%- for mapping_path, data in data.items() %}
      {{ map_file(mapping, mapping_path, data) }}
    {%- endfor %}
  {%- else %}
    {%- set mapping_paths = salt['pillar.get']('postfix:config:' ~ mapping) %}
    {%- if mapping_paths is string %}
      {{ map_file(mapping, mapping_paths, data) }}
    {%- elif mapping_paths is iterable and data is iterable %}
      {%- for mapping_path in mapping_paths[0:data|length] %}
        {{ map_file(mapping ~ '_' ~ salt['file.basename'](mapping_path), mapping_path, data[loop.index0]) }}
      {%- endfor %}
    {%- endif %}
  {%- endif %}
{%- endfor %}
