defmodule SimplePipe do
  defstruct stream_pid: nil

  def create() do
    {:ok, stream_pid} = __MODULE__.start()
    %__MODULE__{stream_pid: stream_pid}
  end

  def read(sstream, timeout \\ nil) do
    make_request(sstream, :read, timeout)
  end

  def write(sstream, msg, timeout \\ nil) do
    make_request(sstream, {:write, msg}, timeout)
  end

  def close(%{stream_pid: pid}) do
    send(pid, :pipe_close)
  end

  def start() do
    {:ok, spawn(__MODULE__, :noreply_loop, [])}
  end

  defp make_request(%{stream_pid: pid}, msg, timeout \\ nil) do
    if Process.alive?(pid) do
      ref = make_ref()
      if timeout,
        do: :timer.send_after(timeout, :pipe_timeout)
      send(pid, {:pipe_request, ref, self(), msg})
      read_response(ref)
    else
      throw :closed
    end
  end

  defp read_response(ref) do
    receive do
      {:pipe_response, ^ref, data} -> data
      :pipe_timeout -> {:error, :timeout}
      _ -> read_response(ref)
    end
  end

  defmodule SimplePipe.State do
    defstruct waiting: [],
      buffered: []
  end

  def noreply_loop() do
    noreply_loop(%SimplePipe.State{})
  end

  def noreply_loop(state) do
    state = flush(state)
    receive do
      {:pipe_request, reply_as, from, msg} ->

        new_state =
          case msg do
            :read ->
              Map.update!(state, :waiting, &(&1 ++ [{from, reply_as}]))

            {:write, msg} ->
              send(from, {:pipe_response, reply_as, :ok})
              Map.update!(state, :buffered, &(&1 ++ [msg]))
          end
        noreply_loop(new_state)

      :pipe_close ->
        write_all(state, :eof)
    end
  end

  def write_all(state, data) do
    Enum.each(state.waiting, fn {waiter_pid, reply_as} ->
      send(waiter_pid, {:pipe_response, reply_as, data})
    end)
  end

  def flush(%{waiting: w, buffered: b} = state) do
    with [{waiter_pid, reply_as} | waiters] <- w,
         [line | lines] <- b do
      send(waiter_pid, {:pipe_response, reply_as, line})

      new_state = %{state | waiting: waiters, buffered: lines}
      if Enum.empty?(lines) do
        new_state
      else
        flush(new_state)
      end
    else
      _ -> state
    end
  end

  defimpl Enumerable do
    def reduce(_, {:halt, acc}, _fun), do: {:halted, acc}
    def reduce(sstream, {:suspend, acc}, fun),
      do: {:suspended, acc, &reduce(sstream, &1, fun)}
    def reduce(sstream, {:cont, acc}, fun) do
      case @for.read(sstream) do
        :eof -> {:done, acc}
        data -> reduce(sstream, fun.(data, acc), fun)
      end
    end

    def slice(_pid),
      do: {:error, __MODULE__}

    def member?(_pid, _term),
      do: {:error, __MODULE__}

    def count(_pid),
      do: {:error, __MODULE__}
  end
end
