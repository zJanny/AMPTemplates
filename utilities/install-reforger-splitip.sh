#!/usr/bin/env bash
# Adds the zJanny/AMPTemplates repository to an AMP install and switches existing
# Arma Reforger instances over to the "Arma Reforger (Split IPs)" template.
#
# Usage (run as the user that owns the AMP datastore, usually "amp"):
#   ./install-reforger-splitip.sh                      # prompts for instance names
#   ./install-reforger-splitip.sh Server01 Server02    # instance names as arguments
#
# Environment overrides:
#   AMP_DATASTORE   instances directory (default: ~/.ampdata/instances)
#   ADS_INSTANCE    ADS instance name   (default: autodetected)
#   ASSUME_YES=1    don't ask for confirmation

set -euo pipefail

REPO_OWNER="zJanny"
REPO_NAME="AMPTemplates"
REPO_BRANCH="main"
REPO_ENTRY="${REPO_OWNER}/${REPO_NAME}:${REPO_BRANCH}"
REPO_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}.git"
SOURCE_NAME="${REPO_OWNER}-${REPO_NAME}-${REPO_BRANCH}"
TEMPLATE_ROOT="arma-reforger"

DATASTORE="${AMP_DATASTORE:-$HOME/.ampdata/instances}"
STAMP="$(date +%Y%m%d-%H%M%S)"

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

command -v ampinstmgr >/dev/null || die "ampinstmgr not found. Is AMP installed?"
command -v python3    >/dev/null || die "python3 is required."
command -v git        >/dev/null || die "git is required."
[ -d "$DATASTORE" ] || die "AMP datastore not found at $DATASTORE (set AMP_DATASTORE)."

owner="$(stat -c %U "$DATASTORE")"
[ "$(id -un)" = "$owner" ] || die "Run this as '$owner' (owner of $DATASTORE), e.g.: sudo -u $owner $0 $*"

# Prints "Yes" or "No" for the instance's Running state.
is_running() {
    ampinstmgr -l 2>/dev/null | awk -v name="$1" '
        /Instance Name/ { found = ($NF == name) }
        found && /Running/ { print $NF; exit }'
}

# ---------------------------------------------------------------- ADS setup --

if [ -n "${ADS_INSTANCE:-}" ]; then
    ADS_DIR="$DATASTORE/$ADS_INSTANCE"
else
    ADS_DIR="$(dirname "$(ls "$DATASTORE"/*/ADSModule.kvp 2>/dev/null | head -1)")"
fi
[ -f "$ADS_DIR/ADSModule.kvp" ] || die "Could not find the ADS instance (set ADS_INSTANCE)."
ADS_NAME="$(basename "$ADS_DIR")"
ADS_KVP="$ADS_DIR/ADSModule.kvp"
TEMPLATES_DIR="$ADS_DIR/Plugins/ADSModule/DeploymentTemplates"
SOURCE_DIR="$TEMPLATES_DIR/$SOURCE_NAME"

info "Using ADS instance $ADS_NAME"

# Prints "ok" if the repo is already listed correctly, otherwise "change".
repo_state="$(python3 - "$ADS_KVP" "$REPO_ENTRY" "$REPO_OWNER/$REPO_NAME" <<'PY'
import json, sys
path, entry, slug = sys.argv[1:]
for line in open(path, encoding="utf-8"):
    if line.startswith("ADS.ConfigurationRepositories="):
        repos = json.loads(line.split("=", 1)[1])
        break
else:
    repos = []
mine = [r for r in repos if slug.lower() in r.lower()]
print("ok" if mine == [entry] else "change")
PY
)"

if [ "$repo_state" = "ok" ]; then
    info "Repository $REPO_ENTRY is already configured"
else
    info "Adding $REPO_ENTRY to ADS.ConfigurationRepositories (ADS will be restarted)"
    ampinstmgr --StopInstance "$ADS_NAME" >/dev/null
    cp -p "$ADS_KVP" "$ADS_KVP.bak-$STAMP"
    python3 - "$ADS_KVP" "$REPO_ENTRY" "$REPO_OWNER/$REPO_NAME" <<'PY'
import json, sys
path, entry, slug = sys.argv[1:]
lines = open(path, encoding="utf-8").read().splitlines()
key = "ADS.ConfigurationRepositories="
idx = next((i for i, l in enumerate(lines) if l.startswith(key)), None)
repos = json.loads(lines[idx][len(key):]) if idx is not None else ["CubeCoders/AMPTemplates:main"]
# Drop every existing form of this repo (full URLs, duplicates, other branches).
repos = [r for r in repos if slug.lower() not in r.lower()] + [entry]
new = key + json.dumps(repos, separators=(",", ":"))
if idx is None:
    lines.append(new)
else:
    lines[idx] = new
open(path, "w", encoding="utf-8").write("\n".join(lines) + "\n")
print("    " + new)
PY
    ampinstmgr --StartInstance "$ADS_NAME" >/dev/null
fi

# ADS fetches configured repositories itself; make sure our copy is present and current.
if [ -d "$SOURCE_DIR/.git" ]; then
    info "Updating template source $SOURCE_NAME"
    git -C "$SOURCE_DIR" fetch -q origin "$REPO_BRANCH"
    git -C "$SOURCE_DIR" reset -q --hard "origin/$REPO_BRANCH"
else
    info "Fetching template source $SOURCE_NAME"
    git clone -q --branch "$REPO_BRANCH" "$REPO_URL" "$SOURCE_DIR"
fi
[ -f "$SOURCE_DIR/$TEMPLATE_ROOT.kvp" ] || die "$TEMPLATE_ROOT.kvp not found in $SOURCE_DIR"

# --------------------------------------------------------- Pick instances --

mapfile -t candidates < <(grep -l "^Meta.ConfigRoot=$TEMPLATE_ROOT.kvp" "$DATASTORE"/*/GenericModule.kvp 2>/dev/null | xargs -r -n1 dirname | xargs -r -n1 basename)

instances=("$@")
if [ ${#instances[@]} -eq 0 ]; then
    [ ${#candidates[@]} -gt 0 ] || die "No Arma Reforger instances found in $DATASTORE."
    echo
    echo "Arma Reforger instances on this machine:"
    for c in "${candidates[@]}"; do
        printf "  %-20s %s\n" "$c" "$(grep -h '^Meta.OriginalSource=' "$DATASTORE/$c/GenericModule.kvp" | cut -d= -f2)"
    done
    echo
    read -r -p "Instance name(s) to switch (space or comma separated, 'all' for every one): " answer
    answer="${answer//,/ }"
    if [ "$answer" = "all" ]; then
        instances=("${candidates[@]}")
    else
        read -r -a instances <<< "$answer"
    fi
fi
[ ${#instances[@]} -gt 0 ] || die "No instances given."

for name in "${instances[@]}"; do
    kvp="$DATASTORE/$name/GenericModule.kvp"
    [ -f "$kvp" ] || die "'$name' is not a generic (template-based) instance in $DATASTORE."
    grep -q "^Meta.ConfigRoot=$TEMPLATE_ROOT.kvp" "$kvp" || die "'$name' is not an Arma Reforger instance."
done

echo
echo "These instances will be stopped, backed up, switched to $SOURCE_NAME and restarted if they were running:"
printf "  %s\n" "${instances[@]}"
if [ "${ASSUME_YES:-0}" != "1" ]; then
    read -r -p "Continue? [y/N] " ok
    [[ "$ok" =~ ^[Yy] ]] || die "Aborted."
fi

# ---------------------------------------------------------- Apply template --

for name in "${instances[@]}"; do
    dir="$DATASTORE/$name"
    echo
    info "$name"

    was_running="$(is_running "$name")"
    if [ "$was_running" = "Yes" ]; then
        info "  stopping"
        ampinstmgr --StopInstance "$name" >/dev/null
    fi

    backup="$dir/template-backup-$STAMP"
    mkdir -p "$backup"
    for f in GenericModule.kvp configmanifest.json metaconfig.json "$TEMPLATE_ROOT/AMP_serverconfig.json"; do
        [ -f "$dir/$f" ] && cp -p "$dir/$f" "$backup/$(basename "$f")"
    done
    info "  backup in $backup"

    python3 - "$dir" "$SOURCE_DIR" "$TEMPLATE_ROOT" "$SOURCE_NAME" <<'PY'
import json, os, re, shutil, sys

inst_dir, src, root, source_name = sys.argv[1:]
kvp_path = os.path.join(inst_dir, "GenericModule.kvp")

def read_kvp(path):
    out = {}
    for line in open(path, encoding="utf-8").read().splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            out[k] = v
    return out

lines = open(kvp_path, encoding="utf-8").read().splitlines()
inst = read_kvp(kvp_path)
tmpl = read_kvp(os.path.join(src, root + ".kvp"))
upstream_path = os.path.join(os.path.dirname(src), "CubeCoders-AMPTemplates-main", root + ".kvp")
upstream = read_kvp(upstream_path) if os.path.exists(upstream_path) else {}

# Values the user sets per instance; the template only provides defaults for them.
keep = {"App.MaxUsers", "App.RemoteAdminPassword", "App.ApplicationIPBinding"}

def resolve(value):
    m = re.fullmatch(r"@IncludeJson\[(.+)\]", value)
    if not m:
        return value
    with open(os.path.join(src, m.group(1)), encoding="utf-8") as f:
        return json.dumps(json.load(f), separators=(",", ":"))

updates = {}
for key, value in tmpl.items():
    if key in keep and key in inst:
        continue
    if key == "App.AppSettings":
        # Keep every setting the instance already has, add new defaults.
        merged = json.loads(value or "{}")
        merged.update(json.loads(inst.get(key) or "{}"))
        updates[key] = json.dumps(merged, separators=(",", ":"))
    elif key == "App.Ports":
        # Keep the instance's port numbers, take everything else from the template.
        current = {p["Ref"]: p for p in json.loads(inst.get(key) or "[]")}
        ports = json.loads(resolve(value))
        for p in ports:
            if p["Ref"] in current:
                p["Port"] = current[p["Ref"]]["Port"]
        updates[key] = json.dumps(ports, separators=(",", ":"))
    elif key in inst or key not in upstream:
        # Keys AMP dropped from the instance as obsolete stay dropped; keys new to this template are added.
        updates[key] = resolve(value)

updates["Meta.OriginalSource"] = source_name

seen = set()
for i, line in enumerate(lines):
    k = line.split("=", 1)[0]
    if k in updates:
        lines[i] = f"{k}={updates[k]}"
        seen.add(k)
lines += [f"{k}={v}" for k, v in updates.items() if k not in seen]

with open(kvp_path, "w", encoding="utf-8") as f:
    f.write("\n".join(lines) + "\n")

shutil.copyfile(os.path.join(src, root + "config.json"), os.path.join(inst_dir, "configmanifest.json"))
shutil.copyfile(os.path.join(src, root + "metaconfig.json"), os.path.join(inst_dir, "metaconfig.json"))

# Server config template, normally downloaded by the update stage matching the release version.
release = json.loads(inst.get("App.AppSettings") or "{}").get("ReleaseVersion")
with open(os.path.join(src, root + "updates.json"), encoding="utf-8") as f:
    stages = json.load(f)
for s in stages:
    if s.get("UpdateSourceArgs") == "AMP_serverconfig.json" and s.get("UpdateSourceConditionValue") == release:
        fname = s["UpdateSourceData"].rsplit("/", 1)[-1]
        target = os.path.join(inst_dir, root)
        os.makedirs(target, exist_ok=True)
        shutil.copyfile(os.path.join(src, fname), os.path.join(target, "AMP_serverconfig.json"))
        print(f"    server config: {fname}")
        break

print(f"    template: {tmpl.get('Meta.DisplayName')} v{tmpl.get('Meta.ConfigVersion')}")
PY

    if [ "$was_running" = "Yes" ]; then
        info "  starting"
        ampinstmgr --StartInstance "$name" >/dev/null
    fi
done

echo
info "Done. Open each instance in AMP and check the new bind IP settings."
info "To undo, stop the instance and copy the files from its template-backup-$STAMP folder back."
