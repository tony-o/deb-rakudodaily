#!/bin/bash


REBASE=$1
if [ "$REBASE" == '' ]; then
  REBASE="$PWD"
fi

grep -Irl '/home/tony/projects/rakudo/' ./* | grep -v './rebase.sh' | xargs -n 1 sed -i "s|/home/tony/projects/rakudo/|$REBASE|g" 
