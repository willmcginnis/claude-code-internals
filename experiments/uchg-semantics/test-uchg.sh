#!/bin/bash
# Is macOS `uchg` a WALL or a SPEED BUMP against a same-uid process?
#
# Decides the ~/.claude lockdown design:
#   - if the owner can clear uchg without sudo -> speed bump (stops accidents,
#     not a determined agent) -> root ownership is required for a real wall
#   - if the owner cannot -> uchg alone is sufficient, no chown needed
#
# Operates only on a throwaway mktemp dir. Touches no account or host config.

set -u

D=$(mktemp -d) || exit 1
trap 'chflags nouchg "$D"/f 2>/dev/null; rm -rf "$D"' EXIT

F="$D/f"
printf 'original\n' > "$F"

echo "=== workspace: $D"
echo

echo "--- 1. owner sets uchg (no sudo)"
chflags uchg "$F"
echo "    set rc=$?"
echo "    flags: $(ls -lO "$F" | awk '{print $5}')"
echo

echo "--- 2. write while uchg is set"
if printf 'tampered\n' > "$F" 2>/dev/null; then
  echo "    write SUCCEEDED  <- uchg did NOT block"
else
  echo "    write BLOCKED (rc=$?)  <- uchg blocks writes"
fi
echo "    content: $(cat "$F")"
echo

echo "--- 3. can the OWNER clear uchg without sudo?  [THE DECIDING QUESTION]"
if chflags nouchg "$F" 2>/dev/null; then
  echo "    CLEARED WITHOUT SUDO  -> uchg alone is a SPEED BUMP"
  VERDICT="SPEED BUMP: same-uid process can self-unlock; root ownership needed for a wall"
else
  echo "    could NOT clear (rc=$?)  -> uchg alone is a WALL"
  VERDICT="WALL: uchg alone suffices; no chown required"
fi
echo

echo "--- 4. write after clearing"
printf 'after-clear\n' > "$F" 2>/dev/null && echo "    content: $(cat "$F")"
echo

echo "=== VERDICT: $VERDICT"
