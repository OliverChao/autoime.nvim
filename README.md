`autoime.nvim` is one pluin to free you hand.
It can auto-switch bwteen default ime and the previous one.
This is useful for some non-latin languages like Chinese.
Sometimes we need write non-latin charactors in insert mode and want ime auto-changes to latin while entering the normal mode.
This is the solution used [`im-select`](https://github.com/daipeihust/im-select).

# Requirements
1. [`im-select`](https://github.com/daipeihust/im-select)
2. [`plenary.nvim`](https://github.com/nvim-lua/plenary.nvim) (optinal, only use async funtions)

# Install
Choose your favourate plugin manager.

The fowllowing configuration is used `lazy`:
```lua
{
    "OliverChao/autoime.nvim",
    event = "InsertEnter",
    opts = {
      im_select_path = "<the ime-select path>",
      autoime_default = "com.apple.keylayout.ABC", -- choose the default ime
    },
}
```

If `im-select` is execuable directly, you needn't set `im_select_path`.

# License
The MIT License (MIT)

# Thanks
[`smartim`](https://github.com/ybian/smartim)
[`vim-barbaric`](https://github.com/rlue/vim-barbaric)
