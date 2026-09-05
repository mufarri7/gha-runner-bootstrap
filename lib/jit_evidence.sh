# shellcheck shell=bash

jit_api_collection() {
  local endpoint="$1" key="$2" page=1 response reported_total=-1 page_items page_count collected
  local items='[]' paged_endpoint
  [[ "$endpoint" != *'?'* && "$key" =~ ^[a-z_]+$ ]] || die "Unsafe paginated GitHub collection request."

  while true; do
    (( page <= JIT_API_MAX_PAGES )) || die "GitHub collection exceeded the bounded pagination limit."
    paged_endpoint="${endpoint}?per_page=${JIT_API_PAGE_SIZE}&page=${page}"
    response="$(jit_api GET "$paged_endpoint")"
    jq -e --arg key "$key" '(.total_count | type=="number" and floor==. and .>=0) and (.[$key] | type=="array")' >/dev/null <<<"$response" \
      || die "GitHub returned an invalid $key collection."

    if (( reported_total < 0 )); then
      reported_total="$(jq -r .total_count <<<"$response")"
    else
      [[ "$(jq -r .total_count <<<"$response")" == "$reported_total" ]] || die "GitHub collection total changed during pagination."
    fi
    page_items="$(jq -c --arg key "$key" '.[$key]' <<<"$response")"
    page_count="$(jq 'length' <<<"$page_items")"
    (( page_count <= JIT_API_PAGE_SIZE )) || die "GitHub returned an oversized collection page."
    items="$(jq -cn --argjson current "$items" --argjson next "$page_items" '$current + $next')"
    collected="$(jq 'length' <<<"$items")"
    (( collected <= reported_total )) || die "GitHub collection exceeded its declared total."
    (( collected == reported_total )) && break
    (( page_count == JIT_API_PAGE_SIZE )) || die "GitHub collection ended before its declared total."
    page=$((page + 1))
  done

  jq -e '
    all(.[]; (.id | type=="number" and floor==. and .>0)) and
    (([.[].id] | length) == ([.[].id] | unique | length))
  ' >/dev/null <<<"$items" || die "GitHub collection contains invalid or duplicate identities across pages."
  jq -n --arg key "$key" --argjson total "$reported_total" --argjson items "$items" '{total_count:$total} | .[$key]=$items'
}

jit_download_api() {
  local endpoint="$1" destination="$2" url
  jit_ensure_api_token
  grep -Eq '^[A-Za-z0-9_./?=&%:-]+$' <<<"$endpoint" && [[ "$endpoint" != *..* ]] || die "Unsafe GitHub artifact endpoint."
  url="https://api.github.com/${endpoint}"
  curl --silent --show-error --fail-with-body --location --max-filesize "$JIT_EVIDENCE_MAX_ARCHIVE_BYTES" \
    --url "$url" --output "$destination" \
    --header 'Accept: application/vnd.github+json' \
    --header "X-GitHub-Api-Version: ${GITHUB_API_VERSION}" \
    --config - <<EOF_CURL
header = "Authorization: Bearer ${JIT_API_TOKEN}"
EOF_CURL
}

jit_validate_evidence_archive() {
  local archive="$1" destination="$2" archive_size permissions declared_size actual_size
  local pipeline_status=()
  local entries=()
  archive_size="$(stat -c '%s' "$archive")"
  (( archive_size > 0 && archive_size <= JIT_EVIDENCE_MAX_ARCHIVE_BYTES )) || die "Admission artifact archive exceeds the safe size limit."
  mapfile -t entries < <(LC_ALL=C zipinfo -1 "$archive")
  [[ "${#entries[@]}" == 1 && "${entries[0]}" == admission.json ]] || die "Admission artifact must contain exactly one admission.json file."
  IFS=' ' read -r permissions declared_size < <(LC_ALL=C zipinfo -l "$archive" admission.json | awk '$NF=="admission.json" {print $1, $4}')
  [[ "$permissions" == -* && "$declared_size" =~ ^[0-9]+$ ]] || die "Admission evidence entry must be a regular file."
  (( declared_size > 0 && declared_size <= JIT_EVIDENCE_MAX_JSON_BYTES )) || die "Admission evidence JSON exceeds the safe size limit."
  set +e
  set +o pipefail
  LC_ALL=C unzip -p "$archive" admission.json | head -c "$((JIT_EVIDENCE_MAX_JSON_BYTES + 1))" >"$destination"
  pipeline_status=("${PIPESTATUS[@]}")
  set -o pipefail
  set -e
  actual_size="$(stat -c '%s' "$destination")"
  [[ "${pipeline_status[1]}" == 0 ]] || die "Admission evidence bounded extraction failed."
  (( actual_size <= JIT_EVIDENCE_MAX_JSON_BYTES )) || die "Admission evidence expanded beyond the safe size limit."
  [[ "${pipeline_status[0]}" == 0 ]] || die "Admission evidence ZIP stream is invalid."
  [[ "$actual_size" == "$declared_size" ]] || die "Admission evidence size does not match the archive directory."
  jq -e . "$destination" >/dev/null || die "Admission evidence is not valid JSON."
}

jit_fetch_admission_evidence() (
  set -Eeuo pipefail
  trap - ERR EXIT
  local run_json="$1" job_json="$2" run_id="$3" run_attempt="$4" pr_number="$5" base_sha="$6" head_sha="$7" merge_sha="$8" tree_sha="$9" label="${10}"
  local workflow_id repository_id job_id expected_name artifacts artifact_count listed_artifact artifact_id artifact digest expected_digest actual_digest
  local temporary archive evidence_file evidence artifact_created_epoch evidence_created_epoch run_created_epoch now

  have unzip && have zipinfo && have sha256sum || die "unzip, zipinfo, and sha256sum are required for admission evidence verification."

  workflow_id="$(jq -r .workflow_id <<<"$run_json")"
  repository_id="$(jq -r .repository.id <<<"$run_json")"
  job_id="$(jq -r .id <<<"$job_json")"
  [[ "$workflow_id" =~ ^[1-9][0-9]*$ && "$repository_id" =~ ^[1-9][0-9]*$ && "$job_id" =~ ^[1-9][0-9]*$ ]] \
    || die "Admission run or job identity is invalid."
  expected_name="${JIT_POLICY_EVIDENCE_ARTIFACT_PREFIX}${run_id}-${run_attempt}-${job_id}"
  artifacts="$(jit_api_collection "repos/${JIT_POLICY_REPOSITORY}/actions/runs/${run_id}/artifacts" artifacts)"
  artifact_count="$(jq --arg name "$expected_name" '[.artifacts[] | select(.name==$name)] | length' <<<"$artifacts")"
  [[ "$artifact_count" == 1 ]] || die "Expected exactly one run-attempt-bound admission evidence artifact."
  listed_artifact="$(jq -c --arg name "$expected_name" '.artifacts[] | select(.name==$name)' <<<"$artifacts")"
  artifact_id="$(jq -r .id <<<"$listed_artifact")"
  [[ "$artifact_id" =~ ^[1-9][0-9]*$ ]] || die "Admission artifact identity is invalid."
  artifact="$(jit_api GET "repos/${JIT_POLICY_REPOSITORY}/actions/artifacts/${artifact_id}")"
  jq -e --argjson id "$artifact_id" --arg name "$expected_name" --argjson run_id "$run_id" --argjson repository_id "$repository_id" --arg branch "$JIT_POLICY_TRUSTED_BRANCH" --arg sha "$base_sha" --arg repository "$JIT_POLICY_REPOSITORY" --argjson max_archive "$JIT_EVIDENCE_MAX_ARCHIVE_BYTES" '
    .id==$id and .name==$name and .expired==false and
    (.size_in_bytes | type=="number" and floor==. and .>0) and
    .size_in_bytes<=$max_archive and
    (.digest | type=="string" and test("^sha256:[A-Fa-f0-9]{64}$")) and
    .url==("https://api.github.com/repos/"+$repository+"/actions/artifacts/"+($id|tostring)) and
    .archive_download_url==("https://api.github.com/repos/"+$repository+"/actions/artifacts/"+($id|tostring)+"/zip") and
    .workflow_run.id==$run_id and .workflow_run.repository_id==$repository_id and
    .workflow_run.head_repository_id==$repository_id and .workflow_run.head_branch==$branch and .workflow_run.head_sha==$sha
  ' <<<"$artifact" >/dev/null || die "Admission artifact metadata is not bound to the trusted run."
  [[ "$(jq -S . <<<"$listed_artifact")" == "$(jq -S . <<<"$artifact")" ]] || die "Admission artifact metadata changed between list and get operations."

  temporary="$(mktemp -d "${JIT_DATA_DIR}/evidence.XXXXXX")"
  trap 'rm -rf --one-file-system "$temporary"' EXIT
  archive="${temporary}/evidence.zip"; evidence_file="${temporary}/admission.json"
  jit_download_api "repos/${JIT_POLICY_REPOSITORY}/actions/artifacts/${artifact_id}/zip" "$archive"
  digest="$(jq -r .digest <<<"$artifact")"; expected_digest="${digest#sha256:}"
  actual_digest="$(sha256sum "$archive" | awk '{print $1}')"
  [[ "${actual_digest,,}" == "${expected_digest,,}" ]] || die "Admission artifact digest mismatch."
  jit_validate_evidence_archive "$archive" "$evidence_file"
  evidence="$(cat "$evidence_file")"
  jq -e '
    (keys | sort)==(["admission_job_id","admission_job_name","base_sha","generated_at","head_sha","label","merge_sha","pr_number","repository","run_attempt","run_id","schema_version","tree_sha","workflow_id","workflow_name","workflow_path"] | sort) and
    .schema_version==1 and
    (.run_id|type=="number" and floor==.) and (.run_attempt|type=="number" and floor==.) and
    (.pr_number|type=="number" and floor==.) and (.workflow_id|type=="number" and floor==.) and
    (.admission_job_id|type=="number" and floor==.) and
    ([.repository,.workflow_path,.workflow_name,.admission_job_name,.base_sha,.head_sha,.merge_sha,.tree_sha,.label,.generated_at] | all(type=="string" and length>0))
  ' <<<"$evidence" >/dev/null || die "Admission evidence schema is invalid or contains unexpected fields."
  jq -e --arg repository "$JIT_POLICY_REPOSITORY" --arg workflow_path "$JIT_POLICY_WORKFLOW_PATH" --arg workflow_name "$JIT_POLICY_WORKFLOW_NAME" --arg job_name "$JIT_POLICY_ADMISSION_JOB" \
    --argjson workflow_id "$workflow_id" --argjson job_id "$job_id" --argjson run_id "$run_id" --argjson run_attempt "$run_attempt" --argjson pr_number "$pr_number" \
    --arg base "$base_sha" --arg head "$head_sha" --arg merge "$merge_sha" --arg tree "$tree_sha" --arg label "$label" '
    .repository==$repository and .workflow_path==$workflow_path and .workflow_name==$workflow_name and
    .workflow_id==$workflow_id and .admission_job_name==$job_name and .admission_job_id==$job_id and
    .run_id==$run_id and .run_attempt==$run_attempt and .pr_number==$pr_number and
    .base_sha==$base and .head_sha==$head and .merge_sha==$merge and .tree_sha==$tree and .label==$label
  ' <<<"$evidence" >/dev/null || die "Admission evidence content does not match the exact trusted identity."

  run_created_epoch="$(date -d "$(jq -r .created_at <<<"$run_json")" +%s)"
  artifact_created_epoch="$(date -d "$(jq -r .created_at <<<"$artifact")" +%s)"
  evidence_created_epoch="$(date -d "$(jq -r .generated_at <<<"$evidence")" +%s)"
  now="$(date +%s)"
  (( artifact_created_epoch >= run_created_epoch && artifact_created_epoch <= now + 300 )) || die "Admission artifact timestamp is outside the trusted run window."
  (( evidence_created_epoch >= run_created_epoch && evidence_created_epoch <= artifact_created_epoch + 300 && evidence_created_epoch <= now + 300 )) \
    || die "Admission evidence timestamp is outside the trusted run-attempt window."

  jq -n --argjson artifact_id "$artifact_id" --arg artifact_name "$expected_name" --arg artifact_digest "$digest" --arg artifact_created_at "$(jq -r .created_at <<<"$artifact")" \
    '{artifact_id:$artifact_id,artifact_name:$artifact_name,artifact_digest:$artifact_digest,artifact_created_at:$artifact_created_at}'
)
