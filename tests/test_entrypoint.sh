#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
# Source the entrypoint WITHOUT running main (guarded in the script).
. "$HERE/../source/entrypoint.sh"

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

# Manager v4 is a pip-installed package activated by --enable-manager, NOT a v3 symlink into
# custom_nodes (ComfyUI rejects that path as IMPORT FAILED). remove_stale_manager must therefore
# purge any stale v3 ComfyUI-Manager from the custom_nodes mount and create NO symlink.

# Case A: a real stale ComfyUI-Manager dir is backed up to .bak; NO symlink is created.
MANAGER_SRC="$workdir/baked-manager"; mkdir -p "$MANAGER_SRC"; echo v4 > "$MANAGER_SRC/marker"
CUSTOM_NODES_DIR="$workdir/custom_nodes"; mkdir -p "$CUSTOM_NODES_DIR/ComfyUI-Manager"
echo v3 > "$CUSTOM_NODES_DIR/ComfyUI-Manager/legacy"
remove_stale_manager
assert_true '[ ! -e "$CUSTOM_NODES_DIR/ComfyUI-Manager" ]' "stale dir removed from custom_nodes"
assert_true '[ ! -L "$CUSTOM_NODES_DIR/ComfyUI-Manager" ]' "no symlink pointing at baked manager created"
assert_true '[ -f "$CUSTOM_NODES_DIR/ComfyUI-Manager.bak/legacy" ]' "old 3.x dir preserved in .bak"

# Case B: an existing (v3) symlink is removed, not recreated, and no .bak is made.
rm -rf "$workdir/custom_nodes"; CUSTOM_NODES_DIR="$workdir/custom_nodes"; mkdir -p "$CUSTOM_NODES_DIR"
ln -s /some/old/path "$CUSTOM_NODES_DIR/ComfyUI-Manager"
remove_stale_manager
assert_true '[ ! -L "$CUSTOM_NODES_DIR/ComfyUI-Manager" ]' "existing symlink removed"
assert_true '[ ! -e "$CUSTOM_NODES_DIR/ComfyUI-Manager.bak" ]' "no .bak created for a symlink"

# Case C: stale dir when a .bak already exists → stale copy dropped, existing .bak untouched.
rm -rf "$workdir/custom_nodes"; CUSTOM_NODES_DIR="$workdir/custom_nodes"; mkdir -p "$CUSTOM_NODES_DIR/ComfyUI-Manager"
mkdir -p "$CUSTOM_NODES_DIR/ComfyUI-Manager.bak"; echo keep > "$CUSTOM_NODES_DIR/ComfyUI-Manager.bak/keep"
remove_stale_manager
assert_true '[ ! -e "$CUSTOM_NODES_DIR/ComfyUI-Manager" ]' "stale dir dropped even when .bak exists"
assert_true '[ -f "$CUSTOM_NODES_DIR/ComfyUI-Manager.bak/keep" ]' "pre-existing .bak left intact"

# --- Task 4: dirs_to_chown excludes the big bind mounts ---
COMFYUI_DIR="$workdir/opt/comfyui"; MANAGER_SRC="$workdir/opt/comfyui-manager"
mkdir -p "$COMFYUI_DIR"/{models,output,input,custom_nodes,web,comfy,app} "$MANAGER_SRC"
chown_list="$(dirs_to_chown)"
assert_true 'echo "$chown_list" | grep -qx "$MANAGER_SRC"' "chowns the baked manager"
assert_true 'echo "$chown_list" | grep -qx "$COMFYUI_DIR/web"' "chowns the app web dir"
assert_true '! echo "$chown_list" | grep -qx "$COMFYUI_DIR/models"' "does NOT chown the models mount"
assert_true '! echo "$chown_list" | grep -qx "$COMFYUI_DIR/output"' "does NOT chown the output mount"
assert_true '! echo "$chown_list" | grep -qx "$COMFYUI_DIR/input"' "does NOT chown the input mount"
assert_true '! echo "$chown_list" | grep -qx "$COMFYUI_DIR/custom_nodes"' "does NOT chown the custom_nodes mount"

# --- Node deps: per-pack hash marker in an EPHEMERAL state dir; reinstalls after recreate ---
CUSTOM_NODES_DIR="$workdir/cn2"; mkdir -p "$CUSTOM_NODES_DIR/PackA"
echo "somepkg==1.0" > "$CUSTOM_NODES_DIR/PackA/requirements.txt"
mkdir -p "$CUSTOM_NODES_DIR/PackB"; printf 'open("%s","w")\n' "$workdir/installpy.marker" > "$CUSTOM_NODES_DIR/PackB/install.py"
NODE_DEPS_STATE_DIR="$workdir/state"          # ephemeral (NOT under the custom_nodes mount)
pipbin="$workdir/bin"; mkdir -p "$pipbin"
cat > "$pipbin/pip"    <<'EOF'
#!/usr/bin/env bash
echo "$@" >> "$PIP_LOG"
EOF
cat > "$pipbin/python" <<'EOF'
#!/usr/bin/env bash
echo "$@" >> "$PY_LOG"
EOF
chmod +x "$pipbin/pip" "$pipbin/python"
export PIP_LOG="$workdir/pip.log"; : > "$PIP_LOG"
export PY_LOG="$workdir/py.log";   : > "$PY_LOG"

PATH="$pipbin:$PATH" FORCE_NODE_REQS="" install_node_requirements
assert_eq "1" "$(grep -c 'PackA/requirements.txt' "$PIP_LOG")" "PackA reqs installed on first run"
assert_eq "1" "$(grep -c 'install.py' "$PY_LOG")"              "PackB install.py run on first run"
assert_true '[ -f "$NODE_DEPS_STATE_DIR/PackA.hash" ]'         "PackA hash marker written"
PATH="$pipbin:$PATH" FORCE_NODE_REQS="" install_node_requirements
assert_eq "1" "$(grep -c 'PackA/requirements.txt' "$PIP_LOG")" "unchanged pack is a no-op second run"

# Simulate container RECREATE: the ephemeral state dir is gone -> reinstall
rm -rf "$NODE_DEPS_STATE_DIR"
PATH="$pipbin:$PATH" FORCE_NODE_REQS="" install_node_requirements
assert_eq "2" "$(grep -c 'PackA/requirements.txt' "$PIP_LOG")" "recreate (state wiped) reinstalls PackA"

PATH="$pipbin:$PATH" FORCE_NODE_REQS="1" install_node_requirements
assert_eq "3" "$(grep -c 'PackA/requirements.txt' "$PIP_LOG")" "FORCE_NODE_REQS reinstalls"

# A failing pip must NOT crash the loop (resilience)
cat > "$pipbin/pip" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$pipbin/pip"; rm -rf "$NODE_DEPS_STATE_DIR"
PATH="$pipbin:$PATH" FORCE_NODE_REQS="" install_node_requirements && rc=0 || rc=$?
assert_eq "0" "$rc" "loop survives a failing pip install"

# --- Manager config is ENFORCED every boot from env (default personal_cloud / normal) ---
# NOTE: Manager v4 reads its config ONLY from get_system_user_directory("manager"),
# i.e. "$COMFYUI_DIR/user/__manager/config.ini", cached on first read. network_mode/security_level
# have no env/CLI override in Manager, so the entrypoint enforces them here before main.py.
# personal_cloud + normal is the only combo that unlocks the v4 install/model API on a 0.0.0.0 box.
COMFYUI_DIR="$workdir/opt_mgr_default"; mkdir -p "$COMFYUI_DIR"
MANAGER_CONFIG_SRC="$workdir/tmpl.ini"; printf '[default]\nsecurity_level = weak\nnetwork_mode = public\n' > "$MANAGER_CONFIG_SRC"
( unset MANAGER_SECURITY_LEVEL MANAGER_NETWORK_MODE; seed_manager_config )
cfg="$COMFYUI_DIR/user/__manager/config.ini"
assert_true '[ -f "$cfg" ]' "config seeded when absent"
assert_eq "normal"         "$(sed -n 's/^security_level = //p' "$cfg")" "default security_level is normal"
assert_eq "personal_cloud" "$(sed -n 's/^network_mode = //p'   "$cfg")" "default network_mode is personal_cloud"

# override via env
COMFYUI_DIR="$workdir/opt_mgr_override"; mkdir -p "$COMFYUI_DIR"
MANAGER_SECURITY_LEVEL="weak" MANAGER_NETWORK_MODE="public" seed_manager_config
cfg="$COMFYUI_DIR/user/__manager/config.ini"
assert_eq "weak"   "$(sed -n 's/^security_level = //p' "$cfg")" "MANAGER_SECURITY_LEVEL overrides"
assert_eq "public" "$(sed -n 's/^network_mode = //p'   "$cfg")" "MANAGER_NETWORK_MODE overrides"

# ENFORCED even when a config already exists: a stale public flips to the default on redeploy,
# but unrelated user keys are preserved.
COMFYUI_DIR="$workdir/opt_mgr_stale"; mkdir -p "$COMFYUI_DIR/user/__manager"
printf '[default]\nsecurity_level = strong\nnetwork_mode = public\nsome_user_key = keep\n' > "$COMFYUI_DIR/user/__manager/config.ini"
( unset MANAGER_SECURITY_LEVEL MANAGER_NETWORK_MODE; seed_manager_config )
cfg="$COMFYUI_DIR/user/__manager/config.ini"
assert_eq "normal"         "$(sed -n 's/^security_level = //p' "$cfg")" "stale security_level corrected to normal"
assert_eq "personal_cloud" "$(sed -n 's/^network_mode = //p'   "$cfg")" "stale network_mode corrected to personal_cloud"
assert_true 'grep -qx "some_user_key = keep" "$cfg"' "unrelated user keys preserved"

# --- Fix: maybe_bootstrap_nodes only runs the bootstrap when opted in ---
# Inject a fake bootstrap script that just touches a marker file.
bs_dir="$workdir/bootstrap"; mkdir -p "$bs_dir"
fake_script="$bs_dir/fake-bootstrap.sh"
marker="$bs_dir/marker"
cat > "$fake_script" <<'EOF'
#!/usr/bin/env bash
touch "$BOOTSTRAP_MARKER"
EOF
chmod +x "$fake_script"
export BOOTSTRAP_MARKER="$marker"

# (1) BOOTSTRAP_NODES unset -> no bootstrap, marker absent.
rm -f "$marker"
( unset BOOTSTRAP_NODES; BOOTSTRAP_SCRIPT="$fake_script" maybe_bootstrap_nodes )
assert_true '[ ! -e "$marker" ]' "bootstrap NOT run when BOOTSTRAP_NODES unset"

# (2) BOOTSTRAP_NODES=1 -> bootstrap runs, marker created.
rm -f "$marker"
BOOTSTRAP_NODES=1 BOOTSTRAP_SCRIPT="$fake_script" maybe_bootstrap_nodes
assert_true '[ -e "$marker" ]' "bootstrap run when BOOTSTRAP_NODES=1"

# --- Sage: apply_sage_attention transforms the ComfyUI arg list ---
# (off) args pass through unchanged, no sage flag.
out="$( unset USE_SAGE_ATTENTION; apply_sage_attention --reserve-vram 1 )"
assert_true '! printf "%s" "$out" | grep -q -- "--use-sage-attention"' "toggle off: no --use-sage-attention added"
assert_eq "$(printf '%s\n' --reserve-vram 1)" "$out" "toggle off: args unchanged"

# (on) appends --use-sage-attention.
out="$( USE_SAGE_ATTENTION=1 apply_sage_attention --reserve-vram 1 )"
assert_true 'printf "%s\n" "$out" | grep -qx -- "--use-sage-attention"' "toggle on: --use-sage-attention appended"
assert_true 'printf "%s\n" "$out" | grep -qx -- "--reserve-vram"' "toggle on: other args preserved"

# (on) drops the redundant cross-attention flag.
out="$( USE_SAGE_ATTENTION=1 apply_sage_attention --use-pytorch-cross-attention --reserve-vram 1 )"
assert_true '! printf "%s\n" "$out" | grep -qx -- "--use-pytorch-cross-attention"' "toggle on: cross-attention flag dropped"
assert_true 'printf "%s\n" "$out" | grep -qx -- "--use-sage-attention"' "toggle on: sage flag present when cross-attention was passed"

# (on) no user args -> exactly the sage flag.
out="$( USE_SAGE_ATTENTION=1 apply_sage_attention )"
assert_eq "--use-sage-attention" "$out" "toggle on, no args: exactly the sage flag"

# (explicit 0) treated as off.
out="$( USE_SAGE_ATTENTION=0 apply_sage_attention --cpu )"
assert_true '! printf "%s" "$out" | grep -q -- "--use-sage-attention"' "USE_SAGE_ATTENTION=0 is off"

# --- Task 1: seed_baked_nodes copies baked packs into custom_nodes, never clobbering ---
BAKED_NODES_DIR="$workdir/baked"; mkdir -p "$BAKED_NODES_DIR/PackX" "$BAKED_NODES_DIR/PackY"
echo "req" > "$BAKED_NODES_DIR/PackX/requirements.txt"
echo "code" > "$BAKED_NODES_DIR/PackY/node.py"
CUSTOM_NODES_DIR="$workdir/cn_seed"; mkdir -p "$CUSTOM_NODES_DIR/PackY"
echo "USER-EDIT" > "$CUSTOM_NODES_DIR/PackY/node.py"   # pre-existing user copy must win
seed_baked_nodes
assert_true '[ -f "$CUSTOM_NODES_DIR/PackX/requirements.txt" ]' "seeds a baked pack that is absent"
assert_eq "USER-EDIT" "$(cat "$CUSTOM_NODES_DIR/PackY/node.py")" "does NOT clobber an existing pack"

# Idempotent second run makes no change and does not error.
seed_baked_nodes
assert_true '[ -f "$CUSTOM_NODES_DIR/PackX/requirements.txt" ]' "second seed run is idempotent"

# Absent baked dir is a safe no-op.
( BAKED_NODES_DIR="$workdir/nope"; seed_baked_nodes ) && rc=0 || rc=$?
assert_eq "0" "$rc" "seed_baked_nodes no-ops when baked dir is absent"

# Seeding still copies with USER_ID/GROUP_ID set — the chown branch runs (guarded `|| true`, so a
# non-root harness where chown fails does not break the copy). Real ownership is verified on boot.
CUSTOM_NODES_DIR="$workdir/cn_own"; mkdir -p "$CUSTOM_NODES_DIR"
( USER_ID=1000 GROUP_ID=1000; seed_baked_nodes ) && rc=0 || rc=$?
assert_eq "0" "$rc" "seed_baked_nodes succeeds with USER_ID/GROUP_ID set (chown branch)"
assert_true '[ -f "$CUSTOM_NODES_DIR/PackX/requirements.txt" ]' "seeds pack when USER_ID/GROUP_ID set"

# node_dep_signature is stable and content-sensitive.
sigdir="$workdir/sigp"; mkdir -p "$sigdir"; echo "a==1" > "$sigdir/requirements.txt"
s1="$(node_dep_signature "$sigdir")"
s2="$(node_dep_signature "$sigdir")"
assert_eq "$s1" "$s2" "node_dep_signature is stable for unchanged content"
echo "a==2" > "$sigdir/requirements.txt"
assert_true '[ "$(node_dep_signature "$sigdir")" != "$s1" ]' "node_dep_signature changes when requirements change"

# --- Task 2: write_baked_node_markers pre-seeds markers so the on-boot loop skips baked packs ---
BAKED_NODES_DIR="$workdir/baked2"; mkdir -p "$BAKED_NODES_DIR/PackReq" "$BAKED_NODES_DIR/PackNone"
echo "dep==1" > "$BAKED_NODES_DIR/PackReq/requirements.txt"
echo "noop"   > "$BAKED_NODES_DIR/PackNone/readme.txt"   # no reqs/install.py -> no marker
NODE_DEPS_STATE_DIR="$workdir/state2"
write_baked_node_markers
assert_true '[ -f "$NODE_DEPS_STATE_DIR/PackReq.hash" ]'   "marker written for a pack with requirements"
assert_true '[ ! -f "$NODE_DEPS_STATE_DIR/PackNone.hash" ]' "no marker for a pack without dep inputs"
assert_eq "$(node_dep_signature "$BAKED_NODES_DIR/PackReq")" "$(cat "$NODE_DEPS_STATE_DIR/PackReq.hash")" \
    "marker equals the pack signature (loop will treat it as satisfied)"

# The seeded pack + pre-seeded marker => install_node_requirements SKIPS it (no pip/python calls).
CUSTOM_NODES_DIR="$workdir/cn_skip"; mkdir -p "$CUSTOM_NODES_DIR"
cp -a "$BAKED_NODES_DIR/PackReq" "$CUSTOM_NODES_DIR/PackReq"
skipbin="$workdir/skipbin"; mkdir -p "$skipbin"
printf '#!/usr/bin/env bash\necho called >> "%s"\n' "$workdir/skip.log" > "$skipbin/pip"
cp "$skipbin/pip" "$skipbin/python"; chmod +x "$skipbin/pip" "$skipbin/python"
: > "$workdir/skip.log"
PATH="$skipbin:$PATH" FORCE_NODE_REQS="" install_node_requirements
assert_eq "0" "$(grep -c called "$workdir/skip.log" 2>/dev/null)" \
    "baked pack with pre-seeded marker is skipped by the on-boot loop"

# --- Task 2: create_cache_dirs makes the persistent HF/torch cache under the models mount ---
COMFYUI_DIR="$workdir/opt2/comfyui"; HF_CACHE_DIR="$COMFYUI_DIR/models/.cache"
unset HF_HOME TORCH_HOME
mkdir -p "$COMFYUI_DIR"
create_cache_dirs
assert_true '[ -d "$HF_CACHE_DIR/huggingface" ]' "huggingface cache dir created under models mount"
assert_true '[ -d "$HF_CACHE_DIR/torch" ]'       "torch cache dir created under models mount"

# --- create_cache_dirs honors HF_HOME/TORCH_HOME overrides (independent of HF_CACHE_DIR) ---
COMFYUI_DIR="$workdir/opt3/comfyui"; HF_CACHE_DIR="$COMFYUI_DIR/models/.cache"
mkdir -p "$COMFYUI_DIR"
HF_HOME="$workdir/custom-hf-home"
TORCH_HOME="$workdir/custom-torch-home"
create_cache_dirs
assert_true '[ -d "$HF_HOME" ]'   "custom HF_HOME dir created when overridden"
assert_true '[ -d "$TORCH_HOME" ]' "custom TORCH_HOME dir created when overridden"
assert_true '[ ! -d "$HF_CACHE_DIR/huggingface" ]' "default huggingface cache dir NOT created when HF_HOME overridden"
assert_true '[ ! -d "$HF_CACHE_DIR/torch" ]'       "default torch cache dir NOT created when TORCH_HOME overridden"
unset HF_HOME TORCH_HOME

# --- Category-gated baked-node seeding: master SEED_BAKED_NODES + per-category SEED_*_NODES ---
BAKED_NODES_DIR="$workdir/baked_cat"
for p in TTS-Audio-Suite ComfyUI-WanVideoWrapper ComfyUI-VideoHelperSuite ComfyUI-Frame-Interpolation \
         ComfyUI-KJNodes ComfyUI_essentials ComfyUI_HuggingFace_Downloader; do
    mkdir -p "$BAKED_NODES_DIR/$p"; echo x > "$BAKED_NODES_DIR/$p/marker"
done

# Category mapping is correct.
assert_eq "audio"  "$(baked_node_category TTS-Audio-Suite)"                "TTS-Audio-Suite -> audio"
assert_eq "video"  "$(baked_node_category ComfyUI-WanVideoWrapper)"        "WanVideoWrapper -> video"
assert_eq "video"  "$(baked_node_category ComfyUI-Frame-Interpolation)"    "Frame-Interpolation -> video"
assert_eq "helper" "$(baked_node_category ComfyUI-KJNodes)"                "KJNodes -> helper"
assert_eq "helper" "$(baked_node_category ComfyUI_HuggingFace_Downloader)" "HF Downloader -> helper"
assert_eq ""       "$(baked_node_category SomeUnknownPack)"                "unknown pack -> uncategorized"

# Default (all flags unset): every category seeds.
CUSTOM_NODES_DIR="$workdir/cn_cat_all"; mkdir -p "$CUSTOM_NODES_DIR"
( unset SEED_BAKED_NODES SEED_AUDIO_NODES SEED_VIDEO_NODES SEED_HELPER_NODES; seed_baked_nodes )
assert_true '[ -d "$CUSTOM_NODES_DIR/TTS-Audio-Suite" ]'         "default seeds the audio pack"
assert_true '[ -d "$CUSTOM_NODES_DIR/ComfyUI-WanVideoWrapper" ]' "default seeds a video pack"
assert_true '[ -d "$CUSTOM_NODES_DIR/ComfyUI-KJNodes" ]'         "default seeds a helper pack"

# Master switch off: nothing seeds, even with category flags at default.
CUSTOM_NODES_DIR="$workdir/cn_cat_off"; mkdir -p "$CUSTOM_NODES_DIR"
SEED_BAKED_NODES=0 seed_baked_nodes
assert_true '[ ! -e "$CUSTOM_NODES_DIR/TTS-Audio-Suite" ]'         "SEED_BAKED_NODES=0 seeds nothing (audio)"
assert_true '[ ! -e "$CUSTOM_NODES_DIR/ComfyUI-WanVideoWrapper" ]' "SEED_BAKED_NODES=0 seeds nothing (video)"

# Video category off: video packs skipped; audio + helper still seed.
CUSTOM_NODES_DIR="$workdir/cn_cat_novideo"; mkdir -p "$CUSTOM_NODES_DIR"
SEED_VIDEO_NODES=0 seed_baked_nodes
assert_true '[ ! -e "$CUSTOM_NODES_DIR/ComfyUI-WanVideoWrapper" ]'     "SEED_VIDEO_NODES=0 skips WanVideoWrapper"
assert_true '[ ! -e "$CUSTOM_NODES_DIR/ComfyUI-VideoHelperSuite" ]'    "SEED_VIDEO_NODES=0 skips VideoHelperSuite"
assert_true '[ ! -e "$CUSTOM_NODES_DIR/ComfyUI-Frame-Interpolation" ]' "SEED_VIDEO_NODES=0 skips Frame-Interpolation"
assert_true '[ -d "$CUSTOM_NODES_DIR/TTS-Audio-Suite" ]'              "SEED_VIDEO_NODES=0 still seeds audio"
assert_true '[ -d "$CUSTOM_NODES_DIR/ComfyUI-KJNodes" ]'             "SEED_VIDEO_NODES=0 still seeds helper"

# Audio category off: TTS skipped; video + helper still seed.
CUSTOM_NODES_DIR="$workdir/cn_cat_noaudio"; mkdir -p "$CUSTOM_NODES_DIR"
SEED_AUDIO_NODES=0 seed_baked_nodes
assert_true '[ ! -e "$CUSTOM_NODES_DIR/TTS-Audio-Suite" ]'        "SEED_AUDIO_NODES=0 skips TTS-Audio-Suite"
assert_true '[ -d "$CUSTOM_NODES_DIR/ComfyUI-WanVideoWrapper" ]'  "SEED_AUDIO_NODES=0 still seeds video"
assert_true '[ -d "$CUSTOM_NODES_DIR/ComfyUI_essentials" ]'       "SEED_AUDIO_NODES=0 still seeds helper"

finish
