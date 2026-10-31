--!optimize 2
-- Share one policy per runtime to count every successful editable allocation.
-- Static published assets should use Content.fromUri instead of staging pixels.
local Policy = {}
Policy.__index = Policy

function Policy.new(config)
    config = config or {}
    return setmetatable({
        allowEditableImages = config.allowEditableImages == true,
        editableImagesCreated = 0,
    }, Policy)
end

function Policy:assertAllowed(context)
    assert(self.allowEditableImages == true,
        (context or 'EditableImage allocation') ..
        ': EditableImage is disabled; use a published rbxassetid:// asset or explicitly set allowEditableImages = true')
end

function Policy:recordCreated()
    self.editableImagesCreated += 1
end

return Policy
