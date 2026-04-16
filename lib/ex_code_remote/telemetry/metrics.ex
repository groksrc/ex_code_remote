defmodule ExCodeRemote.Telemetry.Metrics do
  @moduledoc "Defines Telemetry.Metrics specs for all system events. Used by SPEC-8 reporter wiring."

  import Telemetry.Metrics

  def metrics do
    [
      # Dispatcher
      counter("ex_code_remote.dispatcher.command.stop",
        event_name: [:ex_code_remote, :dispatcher, :command, :stop],
        tags: [:machine, :command_type, :status]
      ),
      distribution("ex_code_remote.dispatcher.command.duration",
        event_name: [:ex_code_remote, :dispatcher, :command, :stop],
        measurement: :duration,
        unit: {:native, :millisecond},
        tags: [:machine, :command_type, :status]
      ),

      # Agent connections
      counter("ex_code_remote.agent.connected",
        event_name: [:ex_code_remote, :agent, :connected],
        tags: [:machine]
      ),
      counter("ex_code_remote.agent.disconnected",
        event_name: [:ex_code_remote, :agent, :disconnected],
        tags: [:machine, :reason]
      ),

      # HTTP requests
      counter("ex_code_remote.http.request.stop",
        event_name: [:ex_code_remote, :http, :request, :stop],
        tags: [:method, :route, :status]
      ),
      distribution("ex_code_remote.http.request.duration",
        event_name: [:ex_code_remote, :http, :request, :stop],
        measurement: :duration,
        unit: {:native, :millisecond},
        tags: [:method, :route, :status]
      )
    ]
  end
end
