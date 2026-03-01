-- lua/dcode/telescope.lua
-- Telescope picker for dcode sessions and models.
-- Gracefully falls back to vim.ui.select if Telescope is not installed.

local M = {}

local function has_telescope()
  return pcall(require, "telescope")
end

-- ─── Session picker ──────────────────────────────────────────────────────────

--- Format a session summary line.
---@param s table  Session object from /session
---@return string
local function fmt_session(s)
  local title = s.title or s.id
  if #title > 35 then title = title:sub(1, 32) .. "..." end
  local msgs  = s.messages or 0
  local agent = s.agent or "?"
  local updated = s.updated_at and s.updated_at:sub(1, 16):gsub("T", " ") or "?"
  return string.format("%-36s  %-10s  %3d msgs  %s", title, agent, msgs, updated)
end

--- Open a Telescope picker (or fallback) to browse and resume sessions.
function M.sessions()
  local client  = require("dcode.client")
  local session = require("dcode.session")
  local ui      = require("dcode.ui")

  client.get("/session", function(ok, data)
    if not ok or type(data) ~= "table" or #data == 0 then
      ui.notify("No sessions found (or dcode serve not running)", vim.log.levels.WARN)
      return
    end

    local items = data  -- array of session objects

    if has_telescope() then
      local pickers  = require("telescope.pickers")
      local finders  = require("telescope.finders")
      local conf     = require("telescope.config").values
      local actions  = require("telescope.actions")
      local astate   = require("telescope.actions.state")

      pickers.new({}, {
        prompt_title = "dcode Sessions",
        finder = finders.new_table({
          results = items,
          entry_maker = function(s)
            return {
              value   = s,
              display = fmt_session(s),
              ordinal = (s.title or s.id) .. " " .. (s.agent or ""),
            }
          end,
        }),
        sorter = conf.generic_sorter({}),
        attach_mappings = function(prompt_bufnr, map)
          -- <CR> — resume selected session
          actions.select_default:replace(function()
            actions.close(prompt_bufnr)
            local entry = astate.get_selected_entry()
            if entry then
              session.current_id = entry.value.id
              ui.set_title(entry.value.title or entry.value.id)
              ui.notify("Resumed: " .. entry.value.id, vim.log.levels.INFO)
              local cfg = require("dcode").config
              if not ui.is_open() then ui.open(cfg.window) end
            end
          end)

          -- <C-d> — delete selected session
          map("i", "<C-d>", function()
            local entry = astate.get_selected_entry()
            if entry then
              actions.close(prompt_bufnr)
              require("dcode.session").delete(entry.value.id, nil)
            end
          end)

          -- <C-n> — new session
          map("i", "<C-n>", function()
            actions.close(prompt_bufnr)
            require("dcode.commands").new_session()
          end)

          return true
        end,
      }):find()

    else
      -- Fallback: vim.ui.select
      local choices = {}
      for _, s in ipairs(items) do
        table.insert(choices, fmt_session(s))
      end
      vim.ui.select(choices, { prompt = "dcode Sessions" }, function(_, idx)
        if idx then
          local s = items[idx]
          session.current_id = s.id
          ui.set_title(s.title or s.id)
          ui.notify("Resumed: " .. s.id, vim.log.levels.INFO)
          local cfg = require("dcode").config
          if not ui.is_open() then ui.open(cfg.window) end
        end
      end)
    end
  end)
end

-- ─── Model picker ────────────────────────────────────────────────────────────

--- Open a Telescope picker (or fallback) to switch the active model.
function M.models()
  local client = require("dcode.client")
  local ui     = require("dcode.ui")

  client.get("/model", function(ok, data)
    if not ok or type(data) ~= "table" then
      ui.notify("Could not fetch models", vim.log.levels.WARN)
      return
    end

    -- Flatten map to list of { provider, model_id }
    local items = {}
    for prov, info in pairs(data) do
      local model_id = type(info) == "table" and (info.id or info.ID or "?") or tostring(info)
      table.insert(items, { provider = prov, model = model_id })
    end
    table.sort(items, function(a, b) return a.provider < b.provider end)

    local choices = {}
    for _, item in ipairs(items) do
      table.insert(choices, string.format("%-22s  %s", item.provider, item.model))
    end

    local function apply_choice(idx)
      if not idx then return end
      local chosen = items[idx]
      client.put("/config", { provider = chosen.provider, model = chosen.model }, function(ok2, _)
        if ok2 then
          ui.notify("Switched to " .. chosen.provider .. "/" .. chosen.model, vim.log.levels.INFO)
        else
          ui.notify("Failed to switch model", vim.log.levels.ERROR)
        end
      end)
    end

    if has_telescope() then
      local pickers = require("telescope.pickers")
      local finders = require("telescope.finders")
      local conf    = require("telescope.config").values
      local actions = require("telescope.actions")
      local astate  = require("telescope.actions.state")

      pickers.new({}, {
        prompt_title = "dcode Models",
        finder = finders.new_table({
          results = items,
          entry_maker = function(item)
            return {
              value   = item,
              display = string.format("%-22s  %s", item.provider, item.model),
              ordinal = item.provider .. " " .. item.model,
            }
          end,
        }),
        sorter = conf.generic_sorter({}),
        attach_mappings = function(prompt_bufnr, _)
          require("telescope.actions").select_default:replace(function()
            actions.close(prompt_bufnr)
            local entry = astate.get_selected_entry()
            if entry then
              apply_choice(nil)
              -- apply directly from entry
              local chosen = entry.value
              client.put("/config", { provider = chosen.provider, model = chosen.model }, function(ok2, _)
                if ok2 then
                  ui.notify("Switched to " .. chosen.provider .. "/" .. chosen.model, vim.log.levels.INFO)
                end
              end)
            end
          end)
          return true
        end,
      }):find()
    else
      vim.ui.select(choices, { prompt = "dcode Models" }, function(_, idx)
        apply_choice(idx)
      end)
    end
  end)
end

return M
