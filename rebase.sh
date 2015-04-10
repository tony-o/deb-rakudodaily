#!/bin/sh


if [[ "$1" == '' ]]; then
  echo "Usage: $0 <new path>"
  exit 0
fi

grep -Irl '/home/tony/projects/rakudo/' ./* | grep -v './rebase.sh' | xargs -n 1 sed -i "s|/home/tony/projects/rakudo/|$1|g" 
