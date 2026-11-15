# bash completion for material-lab
_material_lab() {
    local cur prev
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"
    case "$prev" in
        --preset) COMPREPLY=($(compgen -W "red-brick painted-brick cinder-block rubble-wall cobblestone slate sandstone polished-marble terracotta-roof roof-shingles concrete polished-concrete plaster stucco asphalt ceramic-tile floor-tile wood-planks varnished-wood raw-wood bark soil sand gravel grass moss canvas denim carpet leather brushed-steel galvanized-steel diamond-plate copper rusted-steel painted-metal plastic rubber cardboard flat stone fabric organic coated-metal bare-metal" -- "$cur")); return ;;
        --format|--also-export) COMPREPLY=($(compgen -W "glb usdz materialx unreal unity unity-hdrp godot blender substance roblox minecraft-labpbr" -- "$cur")); return ;;
        --repair-albedo) COMPREPLY=($(compgen -W "off auto quilt blend" -- "$cur")); return ;;
        --seamless-mode) COMPREPLY=($(compgen -W "cut blend" -- "$cur")); return ;;
        --polarity) COMPREPLY=($(compgen -W "1 -1" -- "$cur")); return ;;
        --watch|--info|--contact-sheet|--preview|--export|--root) COMPREPLY=($(compgen -d -- "$cur")); return ;;
        --input|--output|--catalog|--validate|--recipe|--save-recipe|--report|--learned-normals|--guide-normals|--save-guide-normals|--diff)
            COMPREPLY=($(compgen -f -- "$cur")); return ;;
    esac
    COMPREPLY=($(compgen -W "--input --output --catalog --watch --validate --label --id --preset --list-presets --authored --height-map --normal-map --normal-map-dx --roughness-map --ao-map --metalness-map --height-strength \
        --polarity --normal-strength --roughness --roughness-variation --roughness-albedo-limit --mid-relief-share --tile-metres --substrate-relief --ao-radius --ao-strength --equalize --seamless \
        --seamless-mode --repair-albedo --metalness --normal-dx --no-tile --bent-normal --learned --learned-normals \
        --learned-cpu-only --guide-normals --guide-weight --save-guide-normals --recipe --saved-recipe --save-recipe \
        --also-export --jobs --report --keep-going --include-unreviewed --info --contact-sheet --preview --diff --export --format \
        --json --version --help --relief-mask-r8 --height-override-r16le --pre-upscale-exec --pre-upscale-arg \
        --pre-upscale-timeout mcp --root" -- "$cur"))
}
complete -o filenames -F _material_lab material-lab
