# Reviewed compatible values for writable API extensions, not response metadata.
# Comparison may omit them; update payloads must preserve the live values.
# Nondefault, malformed and unknown fields remain observable drift.
def normalize_rules:
  map(if .type == "pull_request" then
    .parameters |= (
      if .required_reviewers == [] then del(.required_reviewers) else . end |
      if .require_extra_approval_for_unattributed_changes == true then
        del(.require_extra_approval_for_unattributed_changes) else . end |
      if (.allowed_merge_methods | type) == "array" and
        (.allowed_merge_methods | sort) == ["merge", "rebase", "squash"] then
        del(.allowed_merge_methods) else . end)
  elif .type == "required_status_checks" then
    .parameters |= (
      if .do_not_enforce_on_create == false then del(.do_not_enforce_on_create) else . end |
      .required_status_checks |= sort_by(.context, .integration_id))
  else . end) | sort_by(.type);

# OrganizationAdmin.actor_id is ignored by the REST API.
# https://docs.github.com/en/rest/orgs/rules?apiVersion=2026-03-10
def normalize_bypass:
  map(if .actor_type == "OrganizationAdmin" then .actor_id = 1 else . end) |
  sort_by(.actor_type, .actor_id, .bypass_mode);
def normalize_conditions:
  with_entries(if .key == "ref_name" or .key == "repository_name" then
    .value.include |= sort | .value.exclude |= sort else . end);
def normalize_policy:
  .bypass_actors |= normalize_bypass |
  .conditions |= normalize_conditions |
  .rules |= normalize_rules;
def policy_body:
  del(.id, .node_id, .source, .source_type, .created_at, .updated_at, ._links);

# Validate keys recursively before replacing managed values. Arrays other than
# rules are atomic policy values. New restrictions require source review.
def recognized_keys($wanted):
  if type == "object" then
    ($wanted | type == "object") and
    all(to_entries[]; . as $entry |
      ($wanted | has($entry.key)) and
      ($entry.value | recognized_keys($wanted[$entry.key])))
  elif type == "array" then
    ($wanted | type == "array") and
    all(.[]; . as $item |
      if type == "object" or type == "array" then
        any($wanted[]; . as $shape | $item | recognized_keys($shape))
      else true end)
  else true end;
def prepare_policy($wanted):
  policy_body as $live |
  ($live | normalize_policy) as $normalized |
  ($wanted | normalize_policy) as $normalized_wanted |
  if ($live | type) != "object" or
    ($live.rules | type) != "array" or
    ($live.rules | map(.type) | length != (unique | length)) or
    (($normalized | del(.rules) | recognized_keys($normalized_wanted | del(.rules))) | not) or
    (all($normalized.rules[]; . as $rule |
      any($normalized_wanted.rules[];
        . as $candidate | .type == $rule.type and ($rule | recognized_keys($candidate)))) | not)
  then error("unrecognized ruleset fields or restrictions require manual review")
  else
    # A known extension is approved only at its reviewed compatible value.
    # normalize_rules removed exactly those values; leftover extension keys
    # therefore failed recognized_keys above. Copy actual values, never defaults.
    $wanted | .rules |= map(. as $rule |
      ([$live.rules[] | select(.type == $rule.type)][0] // {}) as $prior |
      if .type == "pull_request" then
        .parameters = (($prior.parameters // {} | with_entries(select(
          .key == "required_reviewers" or .key == "allowed_merge_methods" or
          .key == "require_extra_approval_for_unattributed_changes"))) + .parameters)
      elif .type == "required_status_checks" then
        .parameters = (($prior.parameters // {} | with_entries(select(
          .key == "do_not_enforce_on_create"))) + .parameters)
      else . end)
  end;
