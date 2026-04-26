# dotfiles

macOS and cloud desktop tool configurations.

## Tools

| Tool | Config location | Dotfiles path |
|------|----------------|---------------|
| [AeroSpace](https://github.com/nikitabobko/AeroSpace) | `~/.aerospace.toml` | `aerospace/.aerospace.toml` |
| [cmux](https://cmux.dev) | `~/.config/cmux/settings.json` | `cmux/settings.json` |
| [Sketchybar](https://github.com/FelixKratz/SketchyBar) | `~/.config/sketchybar/` | `sketchybar/` |
| lazygit | `~/.config/lazygit/` | `lazygit/` |
| yazi | `~/.config/yazi/` | `yazi/` |
| zellij | `~/.config/zellij/` | `zellij/` |
| cmux-kiro | `~/.cmux-kiro/` | `cmux-kiro/` |

## Setup

```bash
# AeroSpace
ln -sf ~/dotfiles/aerospace/.aerospace.toml ~/.aerospace.toml

# cmux
ln -sf ~/dotfiles/cmux/settings.json ~/.config/cmux/settings.json

# Sketchybar
rm -rf ~/.config/sketchybar
ln -sf ~/dotfiles/sketchybar ~/.config/sketchybar
```

After linking sketchybar, rebuild the helpers:

```bash
cd ~/.config/sketchybar/helpers && make
```
