defmodule GSMLG.Storage.ImageProcessorTest do
  use ExUnit.Case, async: true

  alias GSMLG.Storage.ImageProcessor

  describe "process/2" do
    test "returns error for invalid image data" do
      assert {:error, {:processing_failed, _}} =
               ImageProcessor.process("fake image data", width: 100)
    end

    test "requires binary data" do
      assert_raise FunctionClauseError, fn ->
        ImageProcessor.process(123, width: 100)
      end
    end
  end
end
