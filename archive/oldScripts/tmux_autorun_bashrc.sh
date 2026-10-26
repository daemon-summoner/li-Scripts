#!/bin/bash

echo '
echo ""
if [[ -z "$TMUX" ]]; then
  IFS= read -t 1 -n 1 -r -s -p "Press any key (except enter) for /bin/bash... " keyPress

  if [ -z "$keyPress" ]; then
    if command -v tmux>/dev/null; then
      if [ "$SSH_CONNECTION" != "" ]; then
        tmux attach-session -t main || tmux new-session -s main
      fi
    fi
  else
    echo ""
    echo ""
  fi
fi
' >> ~/.bashrc


