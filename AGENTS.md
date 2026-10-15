# 正式環境與 public repo 的更新規則

使用者要求：正式 Neovim 環境必須以自己的 public repo 為發布來源。
不得為了讓功能立即生效，直接修改正式環境的本機設定或外掛安裝副本，繞過 repo 的提交與更新流程。

## 來源與目錄

- neiltree 外掛來源：`https://github.com/RChiangjif/neiltree`。
- nvim config 來源：`https://github.com/RChiangjif/nvim`。
- `~/proj/neiltree` 是開發 checkout；`~/.config/nvim` 是正式使用的設定副本；
  `~/.local/share/nvim/lazy/neiltree` 是 Lazy 管理的外掛安裝副本。
- 正式環境執行 repo 安裝在本機的副本是正常行為，但不得把它改成直接引用開發 checkout。
  不得擅自加入 `dir`、`dev = true` 或修改 `runtimepath` 來切換正式環境的來源。

## 修改與發布流程

1. 先確認修改屬於外掛 repo 還是 nvim config repo。全域快捷鍵與快捷鍵表的設定可能屬於後者；
   更新外掛不代表正式設定已註冊新 mapping。
2. 在對應 repo 的開發 checkout 進行修改與驗證。需要修改 nvim config 時，使用獨立 checkout，
   不得直接編輯 `~/.config/nvim` 來交付功能，也不得手動覆寫 Lazy 安裝的外掛檔案。
3. 依使用者授權完成對應 repo 的 commit 與 push，再透過正常的 repo 同步或外掛更新流程更新正式環境。
   若尚未發布或同步，必須明確回報，不能以直接修改本機正式副本代替。
4. 開發測試使用明確指定的測試設定（例如 `nvim -u .../dev-init.lua`）或隔離環境，
   不得因此改動正式環境的來源設定。
5. 保留既有未提交變更，不得把其他工作的修改一併提交、發布或清除。

## 診斷與回報

- 區分「外掛程式」、「nvim config／mapping」與「目前開啟的 Neovim 已載入內容」，分別確認路徑與版本。
- 沒有手動執行 `:Lazy update`，不代表正在使用開發版本：本機 config 的 `_auto_update` 清單
  目前包含 `neiltree`，會在啟動時背景更新。不得未經查證就把自動更新判定為本機開發引用。
- `:Lazy update` 管理外掛，不會同步 nvim config repo；設定 repo 需要獨立的同步流程。
- 回報完成時，明確區分已修改、已提交、已推送與正式環境已更新，不能混為一談。
