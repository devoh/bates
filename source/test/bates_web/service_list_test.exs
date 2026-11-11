defmodule BatesWeb.ServiceListTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias BatesWeb.ServiceList

  test "labels each service's status for assistive technology" do
    html =
      render_component(&ServiceList.list/1,
        services: [%{name: "web", status: "crashed"}]
      )

    assert html =~ ~r{<span class="bates-visually-hidden">: crashed</span>}
  end
end
