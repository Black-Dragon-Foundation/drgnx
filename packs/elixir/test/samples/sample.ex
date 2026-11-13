defmodule Demo.Queue do
  @moduledoc "A small queue."

  def new(limit \\ 8), do: %{items: [], limit: limit}

  def push(%{items: items, limit: limit} = q, item) when length(items) < limit do
    {:ok, %{q | items: items ++ [item]}} # greeting
  end

  def push(_q, _item), do: {:error, :full}
end
