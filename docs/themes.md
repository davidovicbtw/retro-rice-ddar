# Making a DDAR theme

A theme is a single file: `themes/<name>/theme.conf` (bundled), or
`~/.config/ddar/themes/<name>/theme.conf` (yours; a theme there overrides a
bundled theme of the same name). Theme names use `a-z`, `0-9` and `-`.

```sh
mkdir -p ~/.config/ddar/themes/olive
cp ~/.local/share/ddar/themes/retro/theme.conf ~/.config/ddar/themes/olive/
$EDITOR ~/.config/ddar/themes/olive/theme.conf
ddar theme set olive
```

The file is parsed, not executed. Lines look like `key=#rrggbb`, and only
`NAME`, `DESCRIPTION` and `MODE` take text. A missing key falls back to the
`retro` value, with a warning.

| Key | Used for |
|---|---|
| `MODE` | `light` or `dark`: which half of the Matugen scheme to use |
| `face` | panel surface (bar, menus, window chrome) |
| `face_hi` | bevel highlight: top and left edges of raised things |
| `face_lo` | bevel shadow: bottom and right edges, sunken wells, separators |
| `frame` | the outer 1 px outline |
| `text`, `text_dim` | text on `face` |
| `field`, `field_text` | insides of lists, inputs and message boxes |
| `tip`, `tip_text` | tooltips |
| `accent`, `accent_text` | selection, title bars, active workspace, DDAR button, active border |
| `urgent`, `good`, `warn` | critical / charging / warning states |
| `desktop` | reserved for a solid desktop colour |
| `term_bg`, `term_fg`, `color0`..`color15` | terminal palette (kitty) |

Derived automatically, so don't set these: the title-bar gradient end, the
pressed and hover shades, the selection colours and the terminal cursor all
come from `accent` and `face`. That's what keeps an `ACCENT` override or a
Matugen accent coherent.

Tips for keeping the DDAR look:

- `face_hi` should be clearly lighter than `face`, and `face_lo` clearly darker.
  The bevels are the whole look.
- Keep `accent` saturated but not neon. It sits next to flat greys.
- Check readability of `accent_text` on `accent`, and `text_dim` on `face`.
