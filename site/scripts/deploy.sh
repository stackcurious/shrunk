#!/bin/sh
# Deploys this site to ITS OWN Vercel project and refuses anything else.
#
# Why: from a folder named `site`, a bare `vercel --yes` names the project after the
# folder and attaches to whatever project is already called "site" on the team. This
# script links to the project named in package.json ("vercelProject") when no link
# exists, and stops if the existing link points anywhere else.
set -eu
cd "$(dirname "$0")/.."
EXPECTED=$(node -p "require('./package.json').vercelProject")
SCOPE="team_pZghJEp29OpgKyuvbmvGC5WD"
if [ ! -f .vercel/project.json ]; then
  echo "no link yet — linking to '$EXPECTED'"
  vercel link --yes --project "$EXPECTED" --scope "$SCOPE"
fi
ACTUAL=$(node -p "require('./.vercel/project.json').projectName")
if [ "$ACTUAL" != "$EXPECTED" ]; then
  echo "refusing to deploy: .vercel/project.json is linked to '$ACTUAL', this site belongs to '$EXPECTED'" >&2
  exit 1
fi
exec vercel --prod --yes
