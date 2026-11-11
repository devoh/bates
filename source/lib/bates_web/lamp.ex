defmodule BatesWeb.Lamp do
  @moduledoc """
  Status lamps shown beside apps and services.
  """
  use Phoenix.Component

  @doc """
  Returns the lamp state for an app or service status. Only apps report
  "partial".
  """
  def state("up"), do: "running"
  def state("down"), do: "stopped"
  def state("starting"), do: "starting"
  def state("partial"), do: "partial"
  def state("crashed"), do: "error"
  def state(_), do: "stopped"

  @doc "Renders a lamp in the given state."
  attr(:state, :string, required: true)

  def lamp(assigns) do
    ~H"""
    <span class={"bates-lamp bates-state--#{@state}"} aria-hidden="true"></span>
    """
  end
end
