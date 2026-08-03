--!strict

local History = {}
History.__index = History

function History.new(copyValue: (any) -> any, initial: any)
	return setmetatable({ Copy = copyValue, Present = copyValue(initial), Undo = {}, Redo = {}, Limit = 150 }, History)
end

function History:Get(): any return self.Present end

function History:Replace(value: any, record: boolean?)
	if record ~= false then
		table.insert(self.Undo, self.Copy(self.Present))
		if #self.Undo > self.Limit then table.remove(self.Undo, 1) end
		table.clear(self.Redo)
	end
	self.Present = self.Copy(value)
end

function History:Transact(mutator: (any) -> ())
	local nextValue = self.Copy(self.Present)
	mutator(nextValue)
	self:Replace(nextValue, true)
end

function History:UndoOnce(): boolean
	local value = table.remove(self.Undo)
	if not value then return false end
	table.insert(self.Redo, self.Copy(self.Present))
	self.Present = value
	return true
end

function History:RedoOnce(): boolean
	local value = table.remove(self.Redo)
	if not value then return false end
	table.insert(self.Undo, self.Copy(self.Present))
	self.Present = value
	return true
end

function History:Clear()
	table.clear(self.Undo)
	table.clear(self.Redo)
end

return History
