defmodule GSMLG.NxTest do
  use ExUnit.Case

  describe "GSMLG.Nx" do
    test "defines start_link/1 for supervision tree" do
      # The module is a Supervisor for Whisper AI serving
      assert function_exported?(GSMLG.Nx, :start_link, 1)
    end

    test "defines whisper_serving/0 for speech-to-text" do
      # whisper_serving/0 creates the Bumblebee serving config
      assert function_exported?(GSMLG.Nx, :whisper_serving, 0)
    end
  end
end
