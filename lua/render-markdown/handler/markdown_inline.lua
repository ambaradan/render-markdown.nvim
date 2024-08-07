local component = require('render-markdown.component')
local context = require('render-markdown.context')
local logger = require('render-markdown.logger')
local state = require('render-markdown.state')
local str = require('render-markdown.str')
local ts = require('render-markdown.ts')
local util = require('render-markdown.util')

---@class render.md.handler.buf.MarkdownInline
---@field private buf integer
---@field private config render.md.BufferConfig
---@field private marks render.md.Mark[]
local Handler = {}
Handler.__index = Handler

---@param buf integer
---@return render.md.handler.buf.MarkdownInline
function Handler.new(buf)
    local self = setmetatable({}, Handler)
    self.buf = buf
    self.config = state.get_config(buf)
    self.marks = {}
    return self
end

---@param root TSNode
---@return render.md.Mark[]
function Handler:parse(root)
    context.get(self.buf):query(root, state.inline_query, function(capture, node)
        local info = ts.info(node, self.buf)
        logger.debug_node_info(capture, info)
        if capture == 'code' then
            self:code(info)
        elseif capture == 'shortcut' then
            self:shortcut(info)
        elseif capture == 'link' then
            self:link(info)
        else
            logger.unhandled_capture('inline', capture)
        end
    end)
    return self.marks
end

---@private
---@param mark render.md.Mark
function Handler:add(mark)
    logger.debug('mark', mark)
    table.insert(self.marks, mark)
end

---@private
---@param info render.md.NodeInfo
function Handler:code(info)
    local code = self.config.code
    if not code.enabled then
        return
    end
    if not vim.tbl_contains({ 'normal', 'full' }, code.style) then
        return
    end
    self:add({
        conceal = true,
        start_row = info.start_row,
        start_col = info.start_col,
        opts = {
            end_row = info.end_row,
            end_col = info.end_col,
            hl_group = code.highlight_inline,
        },
    })
end

---@private
---@param info render.md.NodeInfo
function Handler:shortcut(info)
    local callout = component.callout(self.config, info.text, 'exact')
    if callout ~= nil then
        self:callout(info, callout)
        return
    end
    local checkbox = component.checkbox(self.config, info.text, 'exact')
    if checkbox ~= nil then
        self:checkbox(info, checkbox)
        return
    end
    local line = vim.api.nvim_buf_get_lines(self.buf, info.start_row, info.start_row + 1, false)[1]
    if line:find('[' .. info.text .. ']', 1, true) ~= nil then
        self:wiki_link(info)
    end
end

---@private
---@param info render.md.NodeInfo
---@param callout render.md.CustomComponent
function Handler:callout(info, callout)
    ---Support for overriding title: https://help.obsidian.md/Editing+and+formatting/Callouts#Change+the+title
    ---@return string, string?
    local function custom_title()
        local content = ts.parent(self.buf, info, 'inline')
        if content ~= nil then
            local line = str.split(content.text, '\n')[1]
            if #line > #callout.raw and vim.startswith(line:lower(), callout.raw:lower()) then
                local icon = str.split(callout.rendered, ' ')[1]
                local title = vim.trim(line:sub(#callout.raw + 1))
                return icon .. ' ' .. title, ''
            end
        end
        return callout.rendered, nil
    end

    if not self.config.quote.enabled then
        return
    end
    local text, conceal = custom_title()
    self:add({
        conceal = true,
        start_row = info.start_row,
        start_col = info.start_col,
        opts = {
            end_row = info.end_row,
            end_col = info.end_col,
            virt_text = { { text, callout.highlight } },
            virt_text_pos = 'overlay',
            conceal = conceal,
        },
    })
end

---@private
---@param info render.md.NodeInfo
---@param checkbox render.md.CustomComponent
function Handler:checkbox(info, checkbox)
    -- Requires inline extmarks
    if not self.config.checkbox.enabled or not util.has_10 then
        return
    end
    self:add({
        conceal = true,
        start_row = info.start_row,
        start_col = info.start_col,
        opts = {
            end_row = info.end_row,
            end_col = info.end_col,
            virt_text = { { str.pad_to(info.text, checkbox.rendered), checkbox.highlight } },
            virt_text_pos = 'inline',
            conceal = '',
        },
    })
end

---@private
---@param info render.md.NodeInfo
function Handler:wiki_link(info)
    -- Requires inline extmarks
    if not self.config.link.enabled or not util.has_10 then
        return
    end
    local text = info.text:sub(2, -2)
    local parts = str.split(text, '|')
    local icon, highlight = self:dest_virt_text(parts[1])
    self:add({
        conceal = true,
        start_row = info.start_row,
        start_col = info.start_col - 1,
        opts = {
            end_row = info.end_row,
            end_col = info.end_col + 1,
            virt_text = { { icon .. parts[#parts], highlight } },
            virt_text_pos = 'inline',
            conceal = '',
        },
    })
end

---@private
---@param info render.md.NodeInfo
function Handler:link(info)
    -- Requires inline extmarks
    if not self.config.link.enabled or not util.has_10 then
        return
    end
    local icon, highlight = self:link_virt_text(info)
    context.get(self.buf):add_link(info, icon)
    self:add({
        conceal = true,
        start_row = info.start_row,
        start_col = info.start_col,
        opts = {
            end_row = info.end_row,
            end_col = info.end_col,
            virt_text = { { icon, highlight } },
            virt_text_pos = 'inline',
        },
    })
end

---@private
---@param info render.md.NodeInfo
---@return string, string
function Handler:link_virt_text(info)
    local link = self.config.link
    if info.type == 'image' then
        return link.image, link.highlight
    elseif info.type == 'inline_link' then
        local destination = ts.child(self.buf, info, 'link_destination')
        if destination ~= nil then
            return self:dest_virt_text(destination.text)
        end
    end
    return link.hyperlink, link.highlight
end

---@private
---@param destination string
---@return string, string
function Handler:dest_virt_text(destination)
    local link = self.config.link
    for _, link_component in pairs(link.custom) do
        if destination:find(link_component.pattern) then
            return link_component.icon, link_component.highlight
        end
    end
    return link.hyperlink, link.highlight
end

---@class render.md.handler.MarkdownInline: render.md.Handler
local M = {}

---@param root TSNode
---@param buf integer
---@return render.md.Mark[]
function M.parse(root, buf)
    return Handler.new(buf):parse(root)
end

return M
