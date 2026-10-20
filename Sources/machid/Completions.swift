import Foundation

private let zshScript = #"""
#compdef machid
_machid() {
  local -a commands
  commands=(
    'list:list attached devices'
    'info:show one device'
    'get:read a capability'
    'set:write a capability (volatile)'
    'profile:list, show or apply profiles'
    'macro:list or run macros'
    'rules:list automation and remap rules'
    'doctor:check permissions, devices and files'
    'diagnostics:export a redacted report'
    'completions:print a shell completion script'
  )
  if (( CURRENT == 2 )); then
    _describe 'command' commands
    return
  fi
  case $words[2] in
    profile) (( CURRENT == 3 )) && _values 'profile command' list show apply; _arguments '--device[target device]:id' '--json[JSON output]' ;;
    macro) (( CURRENT == 3 )) && _values 'macro command' list run; _arguments '--json[JSON output]' ;;
    diagnostics) (( CURRENT == 3 )) && _values 'command' export; (( CURRENT == 4 )) && _files ;;
    completions) _values 'shell' zsh bash fish ;;
    *) _arguments '--json[JSON output]' '--all[include unsupported devices]' '--trace[print protocol bytes]' '--definitions[definitions folder]:dir:_files -/' ;;
  esac
}
_machid "$@"
"""#

private let bashScript = #"""
_machid() {
  local cur prev words cword
  cur="${COMP_WORDS[COMP_CWORD]}"
  if [ "$COMP_CWORD" -eq 1 ]; then
    COMPREPLY=( $(compgen -W "list info get set profile macro rules doctor diagnostics completions --version" -- "$cur") )
    return
  fi
  case "${COMP_WORDS[1]}" in
    profile) [ "$COMP_CWORD" -eq 2 ] && COMPREPLY=( $(compgen -W "list show apply" -- "$cur") ) || COMPREPLY=( $(compgen -W "--device --json" -- "$cur") ) ;;
    macro) [ "$COMP_CWORD" -eq 2 ] && COMPREPLY=( $(compgen -W "list run" -- "$cur") ) || COMPREPLY=( $(compgen -W "--json" -- "$cur") ) ;;
    diagnostics) [ "$COMP_CWORD" -eq 2 ] && COMPREPLY=( $(compgen -W "export" -- "$cur") ) || COMPREPLY=( $(compgen -f -- "$cur") ) ;;
    completions) COMPREPLY=( $(compgen -W "zsh bash fish" -- "$cur") ) ;;
    *) COMPREPLY=( $(compgen -W "--json --all --trace --definitions" -- "$cur") ) ;;
  esac
}
complete -F _machid machid
"""#

private let fishScript = #"""
complete -c machid -f
complete -c machid -n __fish_use_subcommand -a "list info get set profile macro rules doctor diagnostics completions"
complete -c machid -n "__fish_seen_subcommand_from profile" -a "list show apply"
complete -c machid -n "__fish_seen_subcommand_from profile" -l device -r -d "target device vvvv:pppp"
complete -c machid -n "__fish_seen_subcommand_from macro" -a "list run"
complete -c machid -n "__fish_seen_subcommand_from diagnostics" -a "export"
complete -c machid -n "__fish_seen_subcommand_from completions" -a "zsh bash fish"
complete -c machid -l json -d "JSON output"
complete -c machid -l all -d "include unsupported devices"
complete -c machid -l trace -d "print protocol bytes"
complete -c machid -l definitions -r -d "definitions folder"
"""#

func runCompletions(_ args: [String]) {
    guard args.count == 1 else { fail("completions needs zsh, bash or fish\n" + usage, code: ExitCode.usage) }
    switch args[0] {
    case "zsh": print(zshScript)
    case "bash": print(bashScript)
    case "fish": print(fishScript)
    default: fail("unknown shell '\(args[0])'; use zsh, bash or fish", code: ExitCode.usage)
    }
}
