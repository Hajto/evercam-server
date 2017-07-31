defmodule EvercamMedia.Snapmail.Snapmailer do
  @moduledoc """
  Provides functions to send schedule snapmail
  """

  use GenStage
  alias EvercamMedia.Snapshot.CamClient
  alias EvercamMedia.Snapshot.Storage

  ################
  ## Client API ##
  ################

  @doc """
  Start the Snapmail server for a given snapmail.
  """
  def start_link(args) do
    GenStage.start_link(__MODULE__, args, name: args[:name])
  end

  @doc """
  Get the state of the snapmail worker.
  """
  def get_state(snapmail_server) do
    GenStage.call(snapmail_server, :get_state)
  end

  @doc """
  Get the configuration of the snapmail worker.
  """
  def get_config(snapmail_server) do
    GenStage.call(snapmail_server, :get_snapmail_config)
  end

  @doc """
  Update the configuration of the snapmail worker
  """
  def update_config(snapmail_server, config) do
    GenStage.cast(snapmail_server, {:update_snapmail_config, config})
  end

  @doc """
  Get a snapshot from the camera and send snapmail
  """
  def get_snapshot(cam_server, {:poll, timestamp}) do
    GenStage.cast(cam_server, {:get_camera_snapshot, timestamp})
  end

  ######################
  ## Server Callbacks ##
  ######################

  @doc """
  Initialize the snapmail server
  """
  def init(args) do
    {:ok, event_manager} = GenEvent.start_link
    {:ok, poller} = EvercamMedia.Snapmail.Poller.start_link(args)
    add_handlers(event_manager, args[:event_handlers])
    args = Map.merge args, %{
      poller: poller,
      event_manager: event_manager
    }
    {:producer, args}
  end

  @doc """
  Server callback for restarting snapmail poller
  """
  def handle_call(:restart_snapmail_poller, _from, state) do
    {:reply, nil, [], state}
  end

  @doc """
  Server callback for stopping snapmail poller
  """
  def handle_call(:stop_snapmail_poller, _from, state) do
    {:reply, nil, [], state}
  end

  @doc """
  Server callback for getting snapmail config
  """
  def handle_call(:get_snapmail_config, _from, state) do
    {:reply, get_config_from_state(:config, state), [], state}
  end

  @doc """
  Server callback for getting worker state
  """
  def handle_call(:get_state, _from, state) do
    {:reply, state, [], state}
  end

  @doc """
  """
  def handle_cast({:get_camera_snapshot, timestamp}, state) do
    _get_snapshots_send_snapmail(state, timestamp)
    {:noreply, [], state}
  end

  @doc """
  Server callback for updating snapmail config
  """
  def handle_cast({:update_snapmail_config, config}, state) do
    updated_config = Map.merge state, config
    GenEvent.sync_notify(state.event_manager, {:update_snapmail_config, updated_config})
    {:noreply, [], updated_config}
  end

  @doc """
  Server callback for camera_reply
  """
  def handle_info({:camera_reply, camera_exid, image, timestamp}, state) do
    data = {camera_exid, timestamp, image}
    GenEvent.sync_notify(state.event_manager, {:got_snapshot, data})
    {:noreply, [], state}
  end

  @doc """
  Take care of unknown messages which otherwise would trigger function clause mismatch error.
  """
  def handle_info(_msg, state) do
    {:noreply, [], state}
  end

  #####################
  # Private functions #
  #####################

  defp add_handlers(event_manager, event_handlers) do
    Enum.each(event_handlers, &GenEvent.add_mon_handler(event_manager, &1,[]))
  end

  defp get_config_from_state(:config, state) do
    Map.get(state, :config)
  end

  defp _get_snapshots_send_snapmail(state, timestamp) do
    config = get_config_from_state(:config, state)
    worker = self()
    get_snapshots_send_snapmail(state, config, timestamp, worker)
  end

  defp get_snapshots_send_snapmail(state, config, timestamp, worker) do
    spawn fn ->
      config.cameras
      |> Enum.map(fn(camera) ->
        case try_snapshot(camera, 1) do
          {:ok, image, true} ->
            send worker, {:camera_reply, camera.camera_exid, image, timestamp}
            %{exid: camera.camera_exid, name: camera.name, data: image}
          {:ok, image, false} -> %{exid: camera.camera_exid, name: camera.name, data: image}
          {:error, _error} -> %{exid: camera.camera_exid, name: camera.name, data: nil}
        end
      end)
      |> send_snapmail(state)
    end
  end

  defp send_snapmail([], _state), do: :noop
  defp send_snapmail(images_list, state) do
    EvercamMedia.UserMailer.snapmail(state.name, state.config.notify_time, state.config.recipients, images_list)
  end

  defp try_snapshot(camera, 3) do
    case Storage.thumbnail_load(camera.camera_exid) do
      {:ok, _, ""} -> {:error, "Failed to get image"}
      {:ok, timestamp, image} ->
        case is_younger_thumbnail(timestamp) do
          true -> {:ok, image, false}
          false -> {:error, "Failed to get image"}
        end
      _ -> {:error, "Failed to get image"}
    end
  end

  defp try_snapshot(camera, attempt) do
    case CamClient.fetch_snapshot(camera) do
      {:ok, image} -> {:ok, image, true}
      {:error, _error} -> try_snapshot(camera, attempt + 1)
    end
  end

  defp is_younger_thumbnail(timestamp) do
    current_date = Calendar.DateTime.now_utc
    thumbnail_date = Calendar.DateTime.Parse.unix!(timestamp)
    case Calendar.DateTime.diff(current_date, thumbnail_date) do
      {:ok, seconds, _, :after} -> is_younder?(seconds)
      _ -> false
    end
  end

  defp is_younder?(seconds) when seconds <= 300, do: true
  defp is_younder?(seconds) when seconds > 300, do: false
end
