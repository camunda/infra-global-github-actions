#!/bin/bash

## Helper functions
## This script requires GNU's cut binary

# Print log
function log {
  set -e

  message=$1
  dry_run=${2:-$DRY_RUN}

  if [ "$dry_run" = "true" ]; then
    >&2 echo -n "[DRY-RUN]: "
  fi
  >&2 echo -e "$message"

}

# Replace {variable} placeholders in template with corresponding values
# ex: render_template "Hello {name}" "name:John"
function render_template {
  set -e

  template=$1

  for v in "${@:2}"; do
    name=$(echo "$v" | cut -d':' -f1)
    value=$(echo "$v" | cut --complement -d':' -f1)
    template=$(
      echo -e "$template" |
        # https://stackoverflow.com/questions/4844854/sed-rare-delimiter-other-than
        sed s$'\001'"{$name}"$'\001'"$value"$'\001''g'
    )
  done

  echo "$template"
}

# GNU binaries
case "$(uname -s)" in
Darwin*)
  eval "date() { gdate \"\$@\"; }"
  eval "cut() { gcut \"\$@\"; }"
  ;;
esac
