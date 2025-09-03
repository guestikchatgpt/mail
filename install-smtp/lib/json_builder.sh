# lib/json_builder.sh — минимальный билдер JSON без внешних зависимостей.
# Глобальные переменные: __JSON, __FIRST

# Экранирование для строк JSON (достаточно для наших данных)
json_escape() {
  # заменяем \, ", и управляющие \n \r \t
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

json_begin() { __JSON="{"; __FIRST=1; }

# низкоуровневый: добавить пару "key":<raw>
json_add_kv_raw() {
  local key="$1" raw="$2"
  if [[ "${__FIRST}" -eq 0 ]]; then __JSON+=","
  else __FIRST=0; fi
  __JSON+="\"$(json_escape "$key")\":${raw}"
}

json_add_string() {
  local key="$1" val="$2"
  json_add_kv_raw "$key" "\"$(json_escape "$val")\""
}

json_add_object() {
  local key="$1" obj="$2"
  json_add_kv_raw "$key" "${obj}"
}

json_add_array_strings() {
  local key="$1"; shift
  local out="[" first=1 x
  for x in "$@"; do
    if [[ $first -eq 0 ]]; then out+=","
    else first=0; fi
    out+="\"$(json_escape "$x")\""
  done
  out+="]"
  json_add_kv_raw "$key" "$out"
}

json_end() { __JSON+="}"; printf '%s' "$__JSON"; }
