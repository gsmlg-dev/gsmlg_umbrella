## Simple Error Modules
## --------------------

# NOTE TO SELF:
# Please don't try to be over-efficient and edgy by dynamically
# defining these exceptions from a list of Module names. It looks
# really fucking bad.

defmodule GSMLG.Mnesia.NoTransactionError do
  @moduledoc false
  defexception [:message]
end

defmodule GSMLG.Mnesia.AlreadyExistsError do
  @moduledoc false
  defexception [:message]
end

defmodule GSMLG.Mnesia.DoesNotExistError do
  @moduledoc false
  defexception [:message]
end

defmodule GSMLG.Mnesia.InvalidOperationError do
  @moduledoc false
  defexception [:message]
end
