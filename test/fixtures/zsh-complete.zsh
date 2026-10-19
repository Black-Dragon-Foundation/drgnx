# Prints the completion candidates zsh offers for a command line, one per line.
#   zsh -f zsh-complete.zsh DRGNX-ZSH-FILE LINE        (env DRGNX_COMPLETE_PRE: a zsh command run before compinit)
# An interactive zsh runs in a pseudo terminal (zsh/zpty) with its own temp ZDOTDIR: it loads compinit, sources
# DRGNX-ZSH-FILE, types LINE and TAB, and a compadd wrapper writes every match to a file.  The line is cleared
# with ^U and never run.  The shell is told to exit and waited for before the temp directory goes.
emulate -L zsh
zmodload zsh/zpty || exit 3
typeset file=$1 line=$2 tmp buf
tmp=$(mktemp -d "${TMPDIR:-/tmp}/drgnx-zcomplete.XXXXXX") || exit 3
mkdir -p "$tmp/home"
cat >"$tmp/home/.zshrc" <<EOF
HISTFILE=/dev/null
SAVEHIST=0
PS1='DRGNX_PROMPT> '
PROMPT_EOL_MARK=''
unsetopt beep
zstyle ':completion:*' list-prompt ''
zstyle ':completion:*' menu no
${DRGNX_COMPLETE_PRE-}
autoload -Uz compinit
compinit -D -u
source '${file//\'/\'\\\'\'}'
compadd() {
  local -a hits
  builtin compadd -O hits "\$@"
  (( \${#hits} )) && print -rl -- "\${hits[@]}" >>'$tmp/hits'
  builtin compadd "\$@"
}
EOF
: >"$tmp/hits"
HOME=$tmp/home ZDOTDIR=$tmp/home TERM=xterm HISTFILE=/dev/null zpty z zsh -d -i || exit 3
# wait for the first prompt
zpty -r z buf '*DRGNX_PROMPT> *' || { zpty -d z; rm -rf "$tmp"; echo "no prompt" >&2; exit 4; }
zpty -w z "print READY_\$((6*7))"
zpty -r z buf '*READY_42*' >/dev/null 2>&1 || { zpty -d z; rm -rf "$tmp"; echo "shell not ready" >&2; exit 4; }
zpty -n -w z "$line"$'\t'
sleep 0.3
zpty -n -w z $'\x15'
zpty -w z "print DONE_\$((6*7))"
zpty -r z buf '*DONE_42*' >/dev/null 2>&1
zpty -w z "exit"
while zpty -r z buf >/dev/null 2>&1; do :; done
zpty -d z
sort -u "$tmp/hits"
rm -rf "$tmp"
