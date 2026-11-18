# autoime.nvim

Remember your input method when leaving Neovim's Insert mode, switch to a default input method for Normal mode, and restore your selection when entering Insert mode again.

The plugin uses [im-select](https://github.com/daipeihust/im-select). It is tested on macOS; choose an appropriate input method ID for other platforms supported by im-select.

## Requirements

- Neovim with `nvim_create_autocmd` support.
- `im-select` installed and executable from Neovim's PATH, or an explicit executable path.

Plenary is no longer required. The asynchronous backend uses `vim.system` when available and `jobstart` on older Neovim versions.

## Configuration

For lazy.nvim:

```lua
{
  "OliverChao/autoime.nvim",
  event = "InsertEnter",
  opts = {
    default_im = "com.apple.keylayout.ABC",
    async_if_able = true,
  },
}
```

To load a local checkout, add:

```lua
dir = vim.fn.expand("~/code/lua/autoime.nvim"),
```

Available options:

| Option | Default | Behavior |
| --- | --- | --- |
| `im_select_path` | `"im-select"` | Executable name or path; paths containing spaces are supported. |
| `default_im` | `"com.apple.keylayout.ABC"` | Input method used after leaving Insert mode. |
| `autoime_enabled` | `true` | Enable automatic switching. |
| `async_if_able` | `false` | Execute both querying and switching asynchronously. Recommended for responsive editing. |
| `timeout_ms` | `1000` | Execution limit for each command, in milliseconds. |
| `notify_on_error` | `true` | Report the first error until a transition succeeds. |
| `_notice` | `false` | Notify after successful input method switches. |

The synchronous default is retained for compatibility. Set `async_if_able = true` to avoid waiting for external commands in mode callbacks. Explicit synchronous mode still waits for querying and switching, with the same timeout and output validation.

`setup()` accepts an omitted options table. Repeated calls replace the configuration and event handlers, and invalidate work from the previous instance.

## Behavior

Queries and switches run one at a time. Rapid mode changes replace pending work with the latest mode, preventing an older switch from overwriting a later restore. If Insert mode resumes before the plugin has started switching to the default input method, it preserves the current selection.

The plugin queries on `InsertLeave`, including temporary exits with Ctrl-O. Its first `InsertEnter` preserves the current input method. It does not poll or query on every character. Neovim does not emit `InsertLeave` for Ctrl-C.

A failed or invalid query preserves the previous selection and does not trigger a default switch. Failed switches preserve the recovery target. If restoration fails and the current input method is still the default, the plugin protects its remembered selection; it cannot distinguish that state from a manual default selection without additional system notifications.

Asynchronous execution keeps Neovim responsive while im-select runs. The system input method still takes time to switch, so a character typed immediately after entering Insert mode can arrive before restoration completes.

## Runtime controls

```lua
local autoime = require("autoime")
autoime.enable_autoime()
autoime.disable_autoime()
autoime.toggle_autoime()
```

The original `disable_samrtim()` spelling remains an alias. `make_ime_default()` and `make_ime_previous()` submit the corresponding mode intent; asynchronous calls return before switching completes. `config`, `default_im`, and `pre_im` remain available as state views.

Disabling or reinitializing cancels pending work and attempts to terminate in-flight commands. Already-issued operating system requests may still take effect. Neovim exit cleans up commands without starting an additional switch.

## Verification

The headless regression suite requires Python 3 for its controllable im-select fixture. It exercises real external processes and mode callbacks without changing the system input method:

```sh
nvim --headless -u NONE -i NONE -l tests/run.lua
AUTOIME_TEST_BACKEND=jobstart nvim --headless -u NONE -i NONE -l tests/run.lua
```

After configuring lazy.nvim to load this local checkout, verify the normal user configuration in a separate Neovim process:

```sh
nvim --headless -i NONE -c "lua dofile('tests/configured.lua')" -c 'qa!'
```

This verifies the loaded source and event behavior using the fixture, then disables the plugin in that test process.

The benchmark queries the real input method but intercepts every switch command:

```sh
nvim --headless -u NONE -i NONE -l scripts/bench.lua
AUTOIME_BENCH_ASYNC=0 nvim --headless -u NONE -i NONE -l scripts/bench.lua
```

Use `AUTOIME_BENCH_PATH` to select an executable and `AUTOIME_BENCH_COUNT` to change the sample count. Each query finishes before the next sample begins. Run with normal operating system access: restricted macOS service access can produce stderr diagnostics and inflate query timings.

## License

MIT.
