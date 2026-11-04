#!/bin/bash
echo "Vigilando cambios en la carpeta fit3..."
while true; do
  if [[ -n $(git status -s) ]]; then
    echo "Cambios detectados. Subiendo a GitHub..."
    git add -A
    git commit -m "Auto-update $(date '+%H:%M:%S')"
    git push origin main
  fi
  sleep 10
done
