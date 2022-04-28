## Simple Error Modules
## --------------------

# NOTE TO SELF:
# Please don't try to be over-efficient and edgy by dynamically
# defining these exceptions from a list of Module names. It looks
# really fucking bad.

defmodule GSMLGMnesia.NoTransactionError do
  @moduledoc false
  defexception [:message]
end

defmodule GSMLGMnesia.AlreadyExistsError do
  @moduledoc false
  defexception [:message]
end

defmodule GSMLGMnesia.DoesNotExistError do
  @moduledoc false
  defexception [:message]
end

defmodule GSMLGMnesia.InvalidOperationError do
  @moduledoc false
  defexception [:message]
end
