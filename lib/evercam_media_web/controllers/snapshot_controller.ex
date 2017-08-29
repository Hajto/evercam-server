defmodule EvercamMediaWeb.SnapshotController do
  use EvercamMediaWeb, :controller
  alias EvercamMedia.Snapshot.CamClient
  alias EvercamMedia.Snapshot.DBHandler
  alias EvercamMedia.Snapshot.Error
  alias EvercamMedia.Snapshot.Storage
  alias EvercamMedia.Validation
  alias EvercamMedia.Util
  alias EvercamMedia.Snapshot.WorkerSupervisor

  @optional_params %{"notes" => nil}

  def live(conn, %{"id" => camera_exid}) do
    case snapshot_with_user(camera_exid, conn.assigns[:current_user], false) do
      {200, response} ->
        conn
        |> put_resp_header("content-type", "image/jpeg")
        |> text(response[:image])
      {code, response} ->
        conn
        |> put_status(code)
        |> json(response)
    end
  end

  def create(conn, %{"id" => camera_exid} = params) do
    params = Map.merge(@optional_params, params)
    user = conn.assigns[:current_user]
    camera = Camera.get_full(camera_exid)
    with true <- Permission.Camera.can_snapshot?(user, camera)
    do
      case fetch_latest_snapshot(camera, params) do
        {200, response} ->
          data = "data:image/jpeg;base64,#{Base.encode64(response[:image])}"
          conn
          |> json(%{created_at: response[:timestamp], notes: response[:notes], data: data})
        {code, response} ->
          conn
          |> put_status(code)
          |> json(response)
      end
    else
      false -> render_error(conn, 403, "Forbidden.")
    end
  end

  def test(conn, params) do
    function = fn -> test_snapshot(params) end
    case exec_with_timeout(function, 15) do
      {200, response} ->
        data = "data:image/jpeg;base64,#{Base.encode64(response[:image])}"
        update_camera_status_online(params["camera_exid"])
        conn
        |> json(%{data: data, status: "ok"})
      {code, response} ->
        Logger.error "[test-snapshot] [#{inspect params}] [#{response.message}]"
        conn
        |> put_status(code)
        |> json(response)
    end
  end

  def thumbnail(conn, %{"id" => camera_exid}) do
    case snapshot_thumbnail(camera_exid, conn.assigns[:current_user], true) do
      {200, response} ->
        conn
        |> put_resp_header("content-type", "image/jpeg")
        |> text(response[:image])
      {code, response} ->
        conn
        |> put_status(code)
        |> put_resp_header("content-type", "image/jpeg")
        |> text(response[:image])
    end
  end

  def latest(conn, %{"id" => camera_exid} = _params) do
    case snapshot_thumbnail(camera_exid, conn.assigns[:current_user], false) do
      {200, response} ->
        data = "data:image/jpeg;base64,#{Base.encode64(response[:image])}"

        conn
        |> json(%{data: data, created_at: response[:timestamp], status: "ok"})
      {code, response} ->
        conn
        |> put_status(code)
        |> json(response)
    end
  end

  def oldest(conn, %{"id" => camera_exid} = _params) do
    case old_snapshot(camera_exid, conn.assigns[:current_user]) do
      {200, response} ->
        data = "data:image/jpeg;base64,#{Base.encode64(response[:image])}"

        conn
        |> json(%{data: data, status: "ok", created_at: response[:created_at]})
      {code, response} ->
        conn
        |> put_status(code)
        |> json(response)
    end
  end

  def nearest(conn, %{"id" => camera_exid, "timestamp" => timestamp} = _params) do
    camera = Camera.get_full(camera_exid)
    timezone = Camera.get_timezone(camera)
    timestamp =
      timestamp
      |> convert_timestamp
      |> convert_to_utc(timezone)

    with true <- Permission.Camera.can_list?(conn.assigns[:current_user], camera) do
      conn
      |> json(%{snapshots: Storage.nearest(camera_exid, timestamp)})
    else
      false -> render_error(conn, 403, "Forbidden.")
    end
  end

  def index(conn, %{"id" => camera_exid, "from" => from, "to" => to, "limit" => "3600", "page" => _page}) do
    camera = Camera.get_full(camera_exid)
    offset = Camera.get_offset(camera)
    from = convert_to_camera_timestamp(from, offset)
    to = convert_to_camera_timestamp(to, offset)

    with true <- Permission.Camera.can_list?(conn.assigns[:current_user], camera) do
      snapshots = Storage.seaweedfs_load_range(camera_exid, from, to)

      conn
      |> json(%{snapshots: snapshots})
    else
      false -> render_error(conn, 403, "Forbidden.")
    end
  end

  def show(conn, %{"id" => camera_exid, "timestamp" => timestamp} = params) do
    timestamp = convert_timestamp(timestamp)
    camera = Camera.get_full(camera_exid)

    with true <- Permission.Camera.can_list?(conn.assigns[:current_user], camera),
        {:ok, image, notes} <- Storage.load(camera_exid, timestamp, params["notes"]) do
      data = "data:image/jpeg;base64,#{Base.encode64(image)}"

      conn
      |> json(%{snapshots: [%{created_at: timestamp, notes: notes, data: data}]})
    else
      false -> render_error(conn, 403, "Forbidden.")
      {:error, :not_found} -> render_error(conn, 404, "Snapshot not found.")
      {:error, error} ->
        Logger.error "[#{camera_exid}] [show_snapshot] [error] [#{inspect error}]"
        render_error(conn, 500, "We dropped the ball.")
    end
  end

  def days(conn, %{"id" => camera_exid, "year" => year, "month" => month}) do
    current_user = conn.assigns[:current_user]
    camera = Camera.get_full(camera_exid)

    with :ok <- ensure_params(:day, conn, {year, month, "01"}),
         :ok <- ensure_camera_exists(conn, camera_exid, camera),
         :ok <- ensure_authorized(conn, current_user, camera)
      do
      timezone = Camera.get_timezone(camera)

      from = construct_timestamp(year, month, "01", "00:00:00", timezone)
      number_of_days_in_month =
        Date.new(String.to_integer(year), String.to_integer(month), 1)
        |> elem(1)
        |> Calendar.Date.number_of_days_in_month
      to =
        from
        |> Calendar.DateTime.add!(number_of_days_in_month * 86_400)
        |> Calendar.DateTime.subtract!(1)
      days = Storage.days(camera_exid, from, to, timezone)

      conn
      |> json(%{days: days})
    end
  end

  def day(conn, %{"id" => camera_exid, "year" => year, "month" => month, "day" => day}) do
    current_user = conn.assigns[:current_user]
    camera = Camera.get_full(camera_exid)

    with :ok <- ensure_params(:day, conn, {year, month, day}),
         :ok <- ensure_camera_exists(conn, camera_exid, camera),
         :ok <- ensure_authorized(conn, current_user, camera)
    do
      timezone = Camera.get_timezone(camera)
      from = construct_timestamp(year, month, day, "00:00:00", timezone)
      to = construct_timestamp(year, month, day, "23:59:59", timezone)
      exists? = Storage.exists_for_day?(camera_exid, from, to, timezone)

      conn
      |> json(%{exists: exists?})
    end
  end

  def hours(conn, %{"id" => camera_exid, "year" => year, "month" => month, "day" => day}) do
    current_user = conn.assigns[:current_user]
    camera = Camera.get_full(camera_exid)

    with :ok <- ensure_params(:day, conn, {year, month, day}),
         :ok <- ensure_camera_exists(conn, camera_exid, camera),
         :ok <- ensure_authorized(conn, current_user, camera)
    do
      timezone = Camera.get_timezone(camera)
      from = construct_timestamp(year, month, day, "00:00:00", timezone)
      to = construct_timestamp(year, month, day, "23:59:59", timezone)
      hours = Storage.hours(camera_exid, from, to, timezone)

      conn
      |> json(%{hours: hours})
    end
  end

  def hour(conn, %{"id" => camera_exid, "year" => year, "month" => month, "day" => day, "hour" => hour}) do
    current_user = conn.assigns[:current_user]
    camera = Camera.get_full(camera_exid)

    with :ok <- ensure_params(:hour, conn, {year, month, day, hour}),
         :ok <- ensure_camera_exists(conn, camera_exid, camera),
         :ok <- ensure_authorized(conn, current_user, camera)
    do
      timezone = Camera.get_timezone(camera)
      hour = String.rjust(hour, 2, ?0)
      hour_datetime = construct_timestamp(year, month, day, "#{hour}:00:00", timezone)
      snapshots = Storage.hour(camera_exid, hour_datetime)

      conn
      |> json(%{snapshots: snapshots})
    end
  end

  #######################
  ## Ensure functions  ##
  #######################

  defp ensure_params(type, conn, params) do
    case Validation.Snapshot.validate_params(type, params) do
      :ok -> :ok
      {:invalid, message} -> render_error(conn, 400, message)
    end
  end

  defp ensure_authorized(conn, user, camera) do
    case Permission.Camera.can_list?(user, camera) do
      true -> :ok
      false -> render_error(conn, 403, "Forbidden.")
    end
  end

  defp ensure_camera_exists(conn, camera_exid, nil) do
    render_error(conn, 404, "The #{camera_exid} camera does not exist.")
  end
  defp ensure_camera_exists(_conn, _camera_exid, _camera), do: :ok

  ######################
  ## Fetch functions  ##
  ######################

  defp old_snapshot(camera_exid, user) do
    camera = Camera.get_full(camera_exid)
    with true <- Permission.Camera.can_snapshot?(user, camera),
         {:ok, image, timestamp} <- Storage.get_or_save_oldest_snapshot(camera_exid)
    do
      {200, %{image: image, created_at: timestamp}}
    else
      {:error, error_image} -> {404, %{image: error_image}}
      false -> {403, %{message: "Forbidden"}}
    end
  end

  defp snapshot_with_user(camera_exid, user, store_snapshot, notes \\ "") do
    camera = Camera.get_full(camera_exid)
    if Permission.Camera.can_snapshot?(user, camera) do
      construct_args(camera, store_snapshot, notes) |> fetch_snapshot
    else
      {403, %{message: "Forbidden"}}
    end
  end

  defp fetch_snapshot(args, attempt \\ 1) do
    response = CamClient.fetch_snapshot(args)
    timestamp = Calendar.DateTime.Format.unix(Calendar.DateTime.now_utc)
    args = Map.put(args, :timestamp, timestamp)

    case {response, args[:is_online], attempt} do
      {{:error, _error}, true, attempt} when attempt <= 3 ->
        fetch_snapshot(args, attempt + 1)
      _ ->
        handle_camera_response(args, response, args[:store_snapshot])
    end
  end

  defp test_snapshot(params) do
    construct_args(params)
    |> CamClient.fetch_snapshot
    |> handle_test_response
  end

  defp snapshot_thumbnail(camera_exid, user, update_thumbnail?) do
    camera = Camera.get_full(camera_exid)
    if update_thumbnail?, do: spawn(fn -> update_thumbnail(camera) end)
    with true <- Permission.Camera.can_snapshot?(user, camera),
         {:ok, timestamp, image} <- Storage.thumbnail_load(camera_exid)
    do
      {200, %{timestamp: timestamp, image: image}}
    else
      {:error, error_image} -> {404, %{image: error_image}}
      false -> {403, %{message: "Forbidden"}}
    end
  end

  defp update_thumbnail(nil), do: :noop
  defp update_thumbnail(camera) do
    if camera.is_online && !Camera.recording?(camera) do
      construct_args(camera, true, "Evercam Thumbnail") |> fetch_snapshot(3)
    end
  end

  defp fetch_latest_snapshot(camera, params) do
    to = Calendar.DateTime.now!("UTC")
    from = to |> Calendar.DateTime.advance!(-3) |> Calendar.DateTime.Format.unix

    case Storage.seaweedfs_load_range(camera.exid, from, Calendar.DateTime.Format.unix(to)) do
      [] ->
        function = fn -> construct_args(camera, true, params["notes"]) |> fetch_snapshot end
        exec_with_timeout(function, 25)
      snapshot_list ->
        snapshot = List.last(snapshot_list)
        {:ok, image, notes} = Storage.load(camera.exid, snapshot.created_at, "#{snapshot.notes}")
        {200, %{timestamp: snapshot.created_at, image: image, notes: notes}}
    end
  end

  ####################
  ## Args functions ##
  ####################

  defp construct_args(camera, store_snapshot, notes) do
    %{
      camera_exid: camera.exid,
      is_online: camera.is_online,
      url: Camera.snapshot_url(camera),
      username: Camera.username(camera),
      password: Camera.password(camera),
      vendor_exid: Camera.get_vendor_attr(camera, :exid),
      timestamp: Calendar.DateTime.Format.unix(Calendar.DateTime.now_utc),
      store_snapshot: store_snapshot,
      notes: notes
    }
  end

  defp construct_args(params) do
    %{
      vendor_exid: params["vendor_id"],
      url: "#{params["external_url"]}/#{params["jpg_url"]}",
      username: params["cam_username"],
      password: params["cam_password"]
    }
  end

  #######################
  ## Handler functions ##
  #######################

  defp handle_camera_response(args, {:ok, data}, true) do
    spawn fn ->
      Util.broadcast_snapshot(args[:camera_exid], data, args[:timestamp])
      Storage.save(args[:camera_exid], args[:timestamp], data, args[:notes])
      DBHandler.update_camera_status(args[:camera_exid], args[:timestamp], true)
    end
    {200, %{image: data, timestamp: args[:timestamp], notes: args[:notes]}}
  end

  defp handle_camera_response(args, {:ok, data}, false) do
    spawn fn ->
      Util.broadcast_snapshot(args[:camera_exid], data, args[:timestamp])
      DBHandler.update_camera_status(args[:camera_exid], args[:timestamp], true)
    end
    {200, %{image: data}}
  end

  defp handle_camera_response(args, {:error, error}, _store_snapshot) do
    Error.parse(error) |> Error.handle(args[:camera_exid], args[:timestamp], error)
  end

  defp handle_test_response({:ok, data}) do
    {200, %{image: data}}
  end

  defp handle_test_response({:error, error}) do
    Error.parse(error) |> Error.handle("", nil, error)
  end

  #######################
  ## Utility functions ##
  #######################

  def exec_with_timeout(function, timeout \\ 5) do
    try do
      Task.async(fn() -> function.() end)
      |> Task.await(:timer.seconds(timeout))
    catch _type, error ->
        Util.error_handler(error)
      {504, %{message: "Request timed out."}}
    end
  end

  defp construct_timestamp(year, month, day, time, timezone) do
    month = String.to_integer(month)
    day = String.to_integer(day)
    [hours, minutes, seconds] = String.split(time, ":")
    year = String.to_integer(year)
    hours = String.to_integer(hours)
    minutes = String.to_integer(minutes)
    seconds = String.to_integer(seconds)

    Calendar.DateTime.from_erl!({{year, month, day}, {hours, minutes, seconds}}, timezone)
    |> Calendar.DateTime.shift_zone!("Etc/UTC")
  end

  defp convert_to_camera_timestamp(timestamp, offset) do
    timestamp
    |> String.to_integer
    |> Calendar.DateTime.Parse.unix!
    |> Calendar.Strftime.strftime!("%Y-%m-%dT%H:%M:%S#{offset}")
    |> Calendar.DateTime.Parse.rfc3339_utc
    |> elem(1)
    |> Calendar.DateTime.Format.unix
  end

  defp update_camera_status_online(camera_exid) when camera_exid in [nil, ""], do: :noop
  defp update_camera_status_online(camera_exid) do
    camera = Camera.get_full(camera_exid)
    if camera do
      case camera.is_online do
        false ->
          timestamp = Calendar.DateTime.Format.unix(Calendar.DateTime.now_utc)
          DBHandler.update_camera_status(camera.exid, timestamp, true)
          Camera.invalidate_camera(camera)
          camera.exid
          |> String.to_atom
          |> Process.whereis
          |> WorkerSupervisor.update_worker(camera)
        true -> ""
      end
    end
  end

  defp convert_timestamp(timestamp) do
    case Calendar.DateTime.Parse.rfc3339_utc(timestamp) do
      {:ok, datetime} ->
        datetime |> Calendar.DateTime.Format.unix
      {:bad_format, nil} ->
        String.to_integer(timestamp)
    end
  end

  defp convert_to_utc(unix_timestamp, timezone) do
    unix_timestamp
    |> Calendar.DateTime.Parse.unix!
    |> Calendar.DateTime.to_erl
    |> Calendar.DateTime.from_erl!(timezone)
    |> Calendar.DateTime.shift_zone!("Etc/UTC")
    |> Calendar.DateTime.Format.unix
  end
end
