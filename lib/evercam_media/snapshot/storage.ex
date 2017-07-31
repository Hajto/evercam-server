defmodule EvercamMedia.Snapshot.Storage do
  require Logger
  alias EvercamMedia.Util

  @root_dir Application.get_env(:evercam_media, :storage_dir)
  @seaweedfs Application.get_env(:evercam_media, :seaweedfs_url)

  def latest(camera_exid) do
    Path.wildcard("#{@root_dir}/#{camera_exid}/snapshots/*")
    |> Enum.reject(fn(x) -> String.match?(x, ~r/thumbnail.jpg/) end)
    |> Enum.reduce("", fn(type, acc) ->
      year = Path.wildcard("#{type}/????/") |> List.last
      month = Path.wildcard("#{year}/??/") |> List.last
      day = Path.wildcard("#{month}/??/") |> List.last
      hour = Path.wildcard("#{day}/??/") |> List.last
      last = Path.wildcard("#{hour}/??_??_???.jpg") |> List.last
      Enum.max_by([acc, "#{last}"], fn(x) -> String.slice(x, -27, 27) end)
    end)
  end

  def seaweedfs_save(camera_exid, timestamp, image, notes, metadata \\ %{motion_level: nil}) do
    hackney = [pool: :seaweedfs_upload_pool]
    app_name = notes_to_app_name(notes)
    directory_path = construct_directory_path(camera_exid, timestamp, app_name, "")
    file_name = construct_file_name(timestamp)
    file_path = directory_path <> file_name
    case HTTPoison.post("#{@seaweedfs}#{file_path}", {:multipart, [{file_path, image, []}]}, [], hackney: hackney) do
      {:ok, response} -> response
      {:error, error} -> Logger.info "[seaweedfs_save] [#{camera_exid}] [#{inspect error}]"
    end
    metadata_save(directory_path, file_name, metadata)
  end

  defp metadata_save(_directory_path, _file_name, %{motion_level: 0}), do: :noop
  defp metadata_save(_directory_path, _file_name, %{motion_level: nil}), do: :noop
  defp metadata_save(directory_path, file_name, metadata) do
    hackney = [pool: :seaweedfs_upload_pool]
    file_path = directory_path <> "metadata.json"
    url = @seaweedfs <> file_path

    data =
      case HTTPoison.get(url, [], hackney: hackney) do
        {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
          body
          |> Poison.decode!
          |> Map.put_new(file_name, metadata)
          |> Poison.encode!
        {:ok, %HTTPoison.Response{status_code: 404}} ->
          Poison.encode!(%{file_name => metadata})
        error ->
          raise "Metadata upload at '#{file_path}' failed with: #{inspect error}"
      end
    case HTTPoison.post(url, {:multipart, [{file_path, data, []}]}, [], hackney: hackney) do
      {:ok, response} -> response
      {:error, error} -> Logger.info "[metadata_save] [#{file_path}] [#{inspect error}]"
    end
  end

  defp metadata_load(url) do
    hackney = [pool: :seaweedfs_download_pool]
    case HTTPoison.get(url, [], hackney: hackney) do
      {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
        Poison.decode!(body)
      {:ok, %HTTPoison.Response{status_code: 404}} ->
        %{}
      error ->
        raise "Metadata download from '#{url}' failed with: #{inspect error}"
    end
  end

  def seaweedfs_thumbnail_export(file_path, image) do
    path = String.replace_leading(file_path, "/storage", "")
    hackney = [pool: :seaweedfs_upload_pool]
    url = "#{@seaweedfs}#{path}"
    case HTTPoison.head(url, [], hackney: hackney) do
      {:ok, %HTTPoison.Response{status_code: 200}} ->
        HTTPoison.put!(url, {:multipart, [{path, image, []}]}, [], hackney: hackney)
      {:ok, %HTTPoison.Response{status_code: 404}} ->
        HTTPoison.post!(url, {:multipart, [{path, image, []}]}, [], hackney: hackney)
      error ->
        raise "Upload for file path '#{file_path}' failed with: #{inspect error}"
    end
  end

  def exists_for_day?(camera_exid, from, to, timezone) do
    hours = hours(camera_exid, from, to, timezone)
    !Enum.empty?(hours)
  end

  def nearest(camera_exid, timestamp) do
    list_of_snapshots =
      camera_exid
      |> get_camera_apps_list
      |> Enum.flat_map(fn(app) -> do_seaweedfs_load_range(camera_exid, timestamp, app) end)
      |> Enum.sort_by(fn(snapshot) -> snapshot.created_at end)

    with nil <- get_snapshot("timestamp", list_of_snapshots, timestamp),
         nil <- get_snapshot("after", list_of_snapshots, timestamp),
         nil <- get_snapshot("before", list_of_snapshots, timestamp) do
      []
    else
      snapshot ->
        {:ok, image, _notes} = load(camera_exid, snapshot.created_at, snapshot.notes)
        data = "data:image/jpeg;base64,#{Base.encode64(image)}"
        [%{created_at: snapshot.created_at, notes: snapshot.notes, data: data}]
    end
  end

  defp get_snapshot("timestamp", snapshots, timestamp) do
    snapshots
    |> Enum.filter(fn(snapshot) -> snapshot.created_at == timestamp end)
    |> List.first
  end
  defp get_snapshot("after", snapshots, timestamp) do
    from_date = parse_timestamp(timestamp)
    snapshots
    |> Enum.reject(fn(snapshot) -> is_before_to?(parse_timestamp(snapshot.created_at), from_date) end)
    |> List.first
  end
  defp get_snapshot("before", snapshots, timestamp) do
    from_date = parse_timestamp(timestamp)
    snapshots
    |> Enum.reject(fn(snapshot) -> is_after_from?(parse_timestamp(snapshot.created_at), from_date) end)
    |> List.last
  end

  def days(camera_exid, from, to, timezone) do
    url_base = "#{@seaweedfs}/#{camera_exid}/snapshots"
    apps_list = get_camera_apps_list(camera_exid)
    from_date = Calendar.Strftime.strftime!(from, "%Y/%m")
    to_date = Calendar.Strftime.strftime!(to, "%Y/%m")

    from_days =
      apps_list
      |> Enum.flat_map(fn(app) -> request_from_seaweedfs("#{url_base}/#{app}/#{from_date}/", "Subdirectories", "Name") end)
      |> Enum.uniq
      |> Enum.map(fn(day) -> parse_hour(from.year, from.month, day, "00:00:00", timezone) end)
      |> Enum.reject(fn(datetime) -> Calendar.DateTime.before?(datetime, from) end)

    to_days =
      apps_list
      |> Enum.flat_map(fn(app) -> request_from_seaweedfs("#{url_base}/#{app}/#{to_date}/", "Subdirectories", "Name") end)
      |> Enum.uniq
      |> Enum.map(fn(day) -> parse_hour(to.year, to.month, day, "00:00:00", timezone) end)
      |> Enum.reject(fn(datetime) -> Calendar.DateTime.after?(datetime, to) end)

    Enum.concat(from_days, to_days)
    |> Enum.map(fn(datetime) -> datetime.day end)
    |> Enum.sort
  end

  def hours(camera_exid, from, to, timezone) do
    url_base = "#{@seaweedfs}/#{camera_exid}/snapshots"
    apps_list = get_camera_apps_list(camera_exid)
    from_date = Calendar.Strftime.strftime!(from, "%Y/%m/%d")
    to_date = Calendar.Strftime.strftime!(to, "%Y/%m/%d")

    from_hours =
      apps_list
      |> Enum.flat_map(fn(app) -> request_from_seaweedfs("#{url_base}/#{app}/#{from_date}/", "Subdirectories", "Name") end)
      |> Enum.uniq
      |> Enum.map(fn(hour) -> parse_hour(from.year, from.month, from.day, "#{hour}:00:00", timezone) end)
      |> Enum.reject(fn(datetime) -> Calendar.DateTime.before?(datetime, from) end)

    to_hours =
      apps_list
      |> Enum.flat_map(fn(app) -> request_from_seaweedfs("#{url_base}/#{app}/#{to_date}/", "Subdirectories", "Name") end)
      |> Enum.uniq
      |> Enum.map(fn(hour) -> parse_hour(to.year, to.month, to.day, "#{hour}:00:00", timezone) end)
      |> Enum.reject(fn(datetime) -> Calendar.DateTime.after?(datetime, to) end)

    Enum.concat(from_hours, to_hours)
    |> Enum.map(fn(datetime) -> datetime.hour end)
    |> Enum.sort
  end

  def hour(camera_exid, hour) do
    url_base = "#{@seaweedfs}/#{camera_exid}/snapshots"
    apps_list = get_camera_apps_list(camera_exid)
    hour_datetime = Calendar.Strftime.strftime!(hour, "%Y/%m/%d/%H")
    dir_paths = lookup_dir_paths(camera_exid, apps_list, hour)

    apps_list
    |> Enum.map(fn(app_name) ->
      {app_name, request_from_seaweedfs("#{url_base}/#{app_name}/#{hour_datetime}/?limit=3600", "Files", "name")}
    end)
    |> Enum.reject(fn({_app_name, files}) -> files == [] end)
    |> Enum.flat_map(fn({app_name, files}) ->
      hour_metadata = metadata_load("#{url_base}/#{app_name}/#{hour_datetime}/metadata.json")

      files
      |> Enum.reject(fn(file_name) -> file_name == "metadata.json" end)
      |> Enum.map(fn(file_name) ->
        metadata = Util.deep_get(hour_metadata, [file_name, "motion_level"], nil)

        Map.get(dir_paths, app_name)
        |> construct_snapshot_record(file_name, app_name, metadata)
      end)
    end)
  end

  def seaweedfs_load_range(camera_exid, from, to) do
    from_date = parse_timestamp(from)
    to_date = parse_timestamp(to)
    camera_exid
    |> get_camera_apps_list
    |> Enum.flat_map(fn(app) -> do_seaweedfs_load_range(camera_exid, from, app) end)
    |> Enum.reject(fn(snapshot) -> not_is_between?(snapshot.created_at, from_date, to_date) end)
    |> Enum.sort_by(fn(snapshot) -> snapshot.created_at end)
  end

  defp do_seaweedfs_load_range(camera_exid, from, app_name) do
    directory_path = construct_directory_path(camera_exid, from, app_name, "")
    hour_metadata = metadata_load("#{@seaweedfs}#{directory_path}metadata.json")

    request_from_seaweedfs("#{@seaweedfs}#{directory_path}?limit=3600", "Files", "name")
    |> Enum.reject(fn(file_name) -> file_name == "metadata.json" end)
    |> Enum.map(fn(file_name) ->
      metadata = Util.deep_get(hour_metadata, [file_name, "motion_level"], nil)
      construct_snapshot_record(directory_path, file_name, app_name, metadata)
    end)
  end

  defp get_camera_apps_list(camera_exid) do
    request_from_seaweedfs("#{@seaweedfs}/#{camera_exid}/snapshots/", "Subdirectories", "Name")
  end

  defp request_from_seaweedfs(url, type, attribute) do
    hackney = [pool: :seaweedfs_download_pool]
    with {:ok, response} <- HTTPoison.get(url, [], hackney: hackney),
         %HTTPoison.Response{status_code: 200, body: body} <- response,
         {:ok, data} <- Poison.decode(body),
         true <- is_list(data[type]) do
      Enum.map(data[type], fn(item) -> item[attribute] end)
    else
      _ -> []
    end
  end

  def thumbnail_load(camera_exid) do
    seaweed_thumbnail_load(camera_exid)
  end

  def seaweed_thumbnail_load(camera_exid) do
    url = "#{@seaweedfs}/#{camera_exid}/snapshots/thumbnail.jpg"
    case ConCache.get(:camera_thumbnail, camera_exid) do
      nil ->
        case HTTPoison.get(url, [], hackney: [pool: :seaweedfs_download_pool]) do
          {:ok, %HTTPoison.Response{status_code: 200, body: snapshot, headers: header}} ->
            {_, last_modified_date} = List.last(header)
            thumbnail_timestamp =
              last_modified_date
              |> Timex.parse!("{RFC1123}")
              |> Timex.format!("{ISO:Extended:Z}")
              |> Calendar.DateTime.Parse.rfc3339_utc
              |> elem(1)
              |> Calendar.DateTime.Format.unix
            ConCache.put(:camera_thumbnail, camera_exid, {Calendar.DateTime.now!("UTC"), thumbnail_timestamp, snapshot})
            {:ok, thumbnail_timestamp, snapshot}
          _error -> {:error, Util.unavailable}
        end
      {_last_save_date, timestamp, img} -> {:ok, timestamp, img}
    end
  end

  def disk_thumbnail_load(camera_exid) do
    "#{@root_dir}/#{camera_exid}/snapshots/thumbnail.jpg"
    |> File.open([:read, :binary, :raw], fn(file) -> IO.binread(file, :all) end)
    |> case do
      {:ok, content} -> {:ok, content}
      {:error, _error} -> {:error, Util.unavailable}
    end
  end

  def thumbnail_options(camera_exid) do
    hackney = [pool: :seaweedfs_upload_pool]
    url = "#{@seaweedfs}/#{camera_exid}/snapshots/thumbnail.jpg"
    case HTTPoison.head(url, [], hackney: hackney) do
      {:ok, %HTTPoison.Response{headers: head, status_code: 200}} -> {:ok, head}
      error ->
        Logger.debug "Upload for file path '#{url}' failed with: #{inspect error}"
    end
  end

  def oldest_snapshot(camera_exid, cloud_recording) do
    url = "#{@seaweedfs}/#{camera_exid}/snapshots/"
    hackney = [pool: :seaweedfs_download_pool]
    with {:notes, notes} <- oldest_directory_name(cloud_recording, :notes, url),
         {:year, year} <- oldest_directory_name(cloud_recording, :year, "#{url}#{notes}/"),
         {:month, month} <- oldest_directory_name(cloud_recording, :month, "#{url}#{notes}/#{year}/"),
         {:day, day} <- oldest_directory_name(cloud_recording, :day, "#{url}#{notes}/#{year}/#{month}/"),
         {:hour, hour} <- oldest_directory_name(cloud_recording, :hour, "#{url}#{notes}/#{year}/#{month}/#{day}/"),
         {:image, oldest_image} <- oldest_directory_name(cloud_recording, :image, "#{url}#{notes}/#{year}/#{month}/#{day}/#{hour}/?limit=3600", "Files", "name") do
      case HTTPoison.get("#{url}#{notes}/#{year}/#{month}/#{day}/#{hour}/#{oldest_image}", [], hackney: hackney) do
        {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
          [minute, second, _] = String.split(oldest_image, "_")
          erl_date = {{to_integer(year), to_integer(month), to_integer(day)}, {to_integer(hour), to_integer(minute), to_integer(second)}}
          {:ok, datetime} = Calendar.DateTime.from_erl(erl_date, "UTC")
          {:ok, body, datetime |> Calendar.DateTime.Format.unix}
        {:error, %HTTPoison.Error{reason: reason}} ->
          {:error, reason}
      end
    else
      _ -> {:error, "Not Found."}
    end
  end

  defp to_integer(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _ -> :error
    end
  end

  def save(camera_exid, timestamp, image, "Evercam Thumbnail"), do: update_cache_and_save_thumbnail(camera_exid, timestamp, image)
  def save(camera_exid, timestamp, image, notes) do
    try do
      seaweedfs_save(camera_exid, timestamp, image, notes)
      update_cache_and_save_thumbnail(camera_exid, timestamp, image)
    catch _type, _error ->
      :noop
    end
  end

  defp oldest_directory_name(cloud_recording, directory, url, type \\ "Subdirectories", attribute \\ "Name")
  defp oldest_directory_name(%CloudRecording{storage_duration: -1}, directory, url, type, attribute) do
    {structure, attr} =
      case directory do
        :hour -> {"Files", "name"}
        _ -> {type, attribute}
      end
    value =
      request_from_seaweedfs(url, type, attribute)
      |> Enum.sort(&(&2 > &1))
      |> exist_oldest_directory(directory, String.match?(url, ~r/archives/), url, structure, attr)
    {directory, value}
  end
  defp oldest_directory_name(_cloud_recording, directory, url, type, attribute) do
    {
      directory,
      request_from_seaweedfs(url, type, attribute)
      |> Enum.filter(fn(d) -> d != "recordings" end)
      |> Enum.sort(&(&2 > &1))
      |> List.first
    }
  end

  defp exist_oldest_directory([tail | _head], _directory, true, _url, _type, _attribute), do: tail
  defp exist_oldest_directory([tail | _head], :image, _bool, _url, _type, _attribute), do: tail
  defp exist_oldest_directory([tail | head], directory, bool, url, type, attribute) do
    case request_from_seaweedfs("#{url}#{tail}/", type, attribute) do
      [] -> exist_oldest_directory(head, directory, bool, url, type, attribute)
      _response -> tail
    end
  end
  defp exist_oldest_directory([], _directory, _bool, _url, _type, _attribute), do: :noop

  def update_cache_and_save_thumbnail(camera_exid, timestamp, image) do
    {last_save_date, _, _img} = ConCache.dirty_get_or_store(:camera_thumbnail, camera_exid, fn() ->
      {Calendar.DateTime.now!("UTC"), timestamp, image}
    end)

    case Calendar.DateTime.diff(Calendar.DateTime.now!("UTC"), last_save_date) do
      {:ok, seconds, _, :after} -> thumbnail_save_seaweedfs(camera_exid, image, timestamp, last_save_date, seconds)
      _ -> ConCache.dirty_put(:camera_thumbnail, camera_exid, {last_save_date, timestamp, image})
    end
  end

  def thumbnail_save_seaweedfs(camera_exid, image, timestamp, _last_save_date, seconds) when seconds > 60 do
    hackney = [pool: :seaweedfs_upload_pool]
    url = "#{@seaweedfs}/#{camera_exid}/snapshots/thumbnail.jpg"
    file_path = "/#{camera_exid}/snapshots/thumbnail.jpg"
    case HTTPoison.post(url, {:multipart, [{file_path, image, []}]}, [], hackney: hackney) do
      {:ok, response} -> response
      {:error, error} -> Logger.info "[thumbnail_save_seaweedfs] [#{camera_exid}] [#{inspect error}]"
    end
    ConCache.dirty_put(:camera_thumbnail, camera_exid, {Calendar.DateTime.now!("UTC"), timestamp, image})
  end
  def thumbnail_save_seaweedfs(camera_exid, image, timestamp, last_save_date, _seconds) do
    ConCache.dirty_put(:camera_thumbnail, camera_exid, {last_save_date, timestamp, image})
  end

  def save_mp4(camera_exid, archive_id, path) do
    "#{path}/#{archive_id}.mp4"
    |> File.open([:read, :binary, :raw], fn(file) -> IO.binread(file, :all) end)
    |> case do
      {:ok, content} -> seaweedfs_save_video_file(camera_exid, archive_id, content)
      {:error, _error} -> {:error, "Failed to read video file."}
    end
  end

  def seaweedfs_save_video_file(camera_exid, archive_id, content) do
    hackney = [pool: :seaweedfs_upload_pool]
    file_path = "/#{camera_exid}/clips/#{archive_id}.mp4"
    post_url = "#{@seaweedfs}#{file_path}"
    case HTTPoison.post(post_url, {:multipart, [{file_path, content, []}]}, [], hackney: hackney) do
      {:ok, _response} -> :noop
      {:error, error} -> Logger.info "[save_video] [#{camera_exid}] [#{archive_id}] [#{inspect error}]"
    end
  end

  def delete_archive(camera_exid, archive_id) do
    hackney = [pool: :seaweedfs_download_pool]
    archive_url = "#{@seaweedfs}/#{camera_exid}/clips/#{archive_id}.mp4"
    Logger.info "[#{camera_exid}] [archive_delete] [#{archive_id}]"
    case HTTPoison.delete("#{archive_url}", [], hackney: hackney) do
      {:ok, _response} -> :noop
      {:error, error} -> Logger.info "[archive_delete] [#{camera_exid}] [#{archive_id}] [#{inspect error}]"
    end
  end

  def import_archive_to_seaweed(max_id) do
    Archive.get_all_with_associations
    |> Enum.filter(fn(archive) -> archive.id < max_id end)
    |> Enum.each(fn(archive) ->
      mp4_url = "http://timelapse.evercam.io/timelapses/#{archive.camera.exid}/archives/#{archive.exid}.mp4"
      case HTTPoison.get(mp4_url, [], hackney: [pool: :seaweedfs_download_pool]) do
        {:ok, %HTTPoison.Response{status_code: 200, body: video}} ->
          file_path = "/#{archive.camera.exid}/clips/#{archive.exid}.mp4"
          upload_url = "#{@seaweedfs}#{file_path}"
          hackney = [pool: :seaweedfs_upload_pool]
          case HTTPoison.head(upload_url, [], hackney: hackney) do
            {:ok, %HTTPoison.Response{status_code: 200}} ->
              HTTPoison.put!(upload_url, {:multipart, [{file_path, video, []}]}, [], hackney: hackney)
            {:ok, %HTTPoison.Response{status_code: 404}} ->
              HTTPoison.post!(upload_url, {:multipart, [{file_path, video, []}]}, [], hackney: hackney)
            _error ->
              :noop
          end
          Logger.info "[archive_import] [success] [#{archive.camera.exid}] [#{archive.exid}]"
        error ->
          Logger.info "[archive_import] [error] [#{archive.camera.exid}] [#{archive.exid}] [#{inspect error}]"
          {:error, :not_found}
      end
    end)
  end

  def load(camera_exid, timestamp, notes) when notes in [nil, ""] do
    with {:error, _error} <- load(camera_exid, timestamp, "Evercam Proxy"),
         {:error, _error} <- load(camera_exid, timestamp, "Evercam Timelapse"),
         {:error, _error} <- load(camera_exid, timestamp, "Evercam SnapMail"),
         {:error, error} <- load(camera_exid, timestamp, "Evercam Thumbnail") do
      {:error, error}
    else
      {:ok, image, notes} -> {:ok, image, notes}
    end
  end
  def load(camera_exid, timestamp, notes) do
    app_name = notes_to_app_name(notes)
    directory_path = construct_directory_path(camera_exid, timestamp, app_name, "")
    file_name = construct_file_name(timestamp)
    url = @seaweedfs <> directory_path <> file_name

    case HTTPoison.get(url, [], hackney: [pool: :seaweedfs_download_pool]) do
      {:ok, %HTTPoison.Response{status_code: 200, body: snapshot}} ->
        {:ok, snapshot, notes}
      _error ->
        {:error, :not_found}
    end
  end

  def cleanup_all do
    CloudRecording.get_all_ephemeral
    |> Enum.map(fn(cloud_recording) -> cleanup(cloud_recording) end)
  end

  def cleanup(%CloudRecording{storage_duration: -1}), do: :noop
  def cleanup(%CloudRecording{status: "paused"}), do: :noop
  def cleanup(%CloudRecording{camera: nil}), do: :noop
  def cleanup(cloud_recording) do
    cloud_recording.camera.exid
    |> list_expired_days_for_camera(cloud_recording)
    |> Enum.each(fn(day_url) -> delete_directory(cloud_recording.camera.exid, day_url) end)
  end

  defp list_expired_days_for_camera(camera_exid, cloud_recording) do
    ["#{@seaweedfs}/#{camera_exid}/snapshots/recordings/"]
    |> list_stored_days_for_camera(["year", "month", "day"])
    |> Enum.filter(fn(day_url) -> expired?(camera_exid, cloud_recording, day_url) end)
    |> Enum.sort
  end

  defp list_stored_days_for_camera(urls, []), do: urls
  defp list_stored_days_for_camera(urls, [_current|rest]) do
    Enum.flat_map(urls, fn(url) ->
      request_from_seaweedfs(url, "Subdirectories", "Name")
      |> Enum.map(fn(path) -> "#{url}#{path}/" end)
    end)
    |> list_stored_days_for_camera(rest)
  end

  defp delete_directory(camera_exid, url) do
    hackney = [pool: :seaweedfs_download_pool, recv_timeout: 30_000_000]
    date = extract_date_from_url(url, camera_exid)
    Logger.info "[#{camera_exid}] [storage_delete] [#{date}]"
    HTTPoison.delete!("#{url}?recursive=true", [], hackney: hackney)
  end

  def expired?(camera_exid, cloud_recording, url) do
    seconds_to_day_before_expiry = (cloud_recording.storage_duration) * (24 * 60 * 60) * (-1)
    day_before_expiry =
      Calendar.DateTime.now_utc
      |> Calendar.DateTime.advance!(seconds_to_day_before_expiry)
      |> Calendar.DateTime.to_date
    url_date = parse_url_date(url, camera_exid)
    Calendar.Date.diff(url_date, day_before_expiry) < 0
  end

  def delete_everything_for(camera_exid) do
    camera_exid
    |> get_camera_apps_list
    |> Enum.map(fn(app_name) -> "#{@seaweedfs}/#{camera_exid}/snapshots/#{app_name}/" end)
    |> list_stored_days_for_camera(["year", "month", "day"])
    |> Enum.each(fn(day_url) -> delete_directory(camera_exid, day_url) end)
  end

  def construct_directory_path(camera_exid, timestamp, app_dir, root_dir \\ @root_dir) do
    timestamp
    |> Calendar.DateTime.Parse.unix!
    |> Calendar.Strftime.strftime!("#{root_dir}/#{camera_exid}/snapshots/#{app_dir}/%Y/%m/%d/%H/")
  end

  def construct_file_name(timestamp) do
    timestamp
    |> Calendar.DateTime.Parse.unix!
    |> Calendar.Strftime.strftime!("%M_%S_%f")
    |> format_file_name
  end

  defp construct_snapshot_record(directory_path, file_name, app_name, motion_level) do
    %{
      created_at: parse_file_timestamp(directory_path, file_name),
      notes: app_name_to_notes(app_name),
      motion_level: motion_level
    }
  end

  defp parse_file_timestamp(directory_path, file_path) do
    [_, _, _, year, month, day, hour] = String.split(directory_path, "/", trim: true)
    [minute, second, _] = String.split(file_path, "_")

    "#{year}-#{month}-#{day}T#{hour}:#{minute}:#{second}Z"
    |> Calendar.DateTime.Parse.rfc3339_utc
    |> elem(1)
    |> Calendar.DateTime.Format.unix
  end

  defp parse_hour(year, month, day, time, timezone) do
    month = String.rjust("#{month}", 2, ?0)
    day = String.rjust("#{day}", 2, ?0)

    "#{year}-#{month}-#{day}T#{time}Z"
    |> Calendar.DateTime.Parse.rfc3339_utc
    |> elem(1)
    |> Calendar.DateTime.shift_zone!(timezone)
  end

  defp parse_url_date(url, camera_exid) do
    url
    |> extract_date_from_url(camera_exid)
    |> String.replace("/", "-")
    |> Calendar.Date.Parse.iso8601!
  end

  defp extract_date_from_url(url, camera_exid) do
    url
    |> String.replace_leading("#{@seaweedfs}/#{camera_exid}/snapshots/", "")
    |> String.replace_trailing("/", "")
  end

  defp format_file_name(<<file_name::bytes-size(6)>>) do
    "#{file_name}000" <> ".jpg"
  end

  defp format_file_name(<<file_name::bytes-size(7)>>) do
    "#{file_name}00" <> ".jpg"
  end

  defp format_file_name(<<file_name::bytes-size(9), _rest :: binary>>) do
    "#{file_name}" <> ".jpg"
  end

  defp lookup_dir_paths(camera_exid, apps_list, datetime) do
    timestamp = Calendar.DateTime.Format.unix(datetime)

    Enum.reduce(apps_list, %{}, fn(app_name, map) ->
      dir_path = construct_directory_path(camera_exid, timestamp, app_name, "")
      Map.put(map, app_name, dir_path)
    end)
  end

  defp app_name_to_notes(name) do
    case name do
      "recordings" -> "Evercam Proxy"
      "thumbnail" -> "Evercam Thumbnail"
      "timelapse" -> "Evercam Timelapse"
      "snapmail" -> "Evercam SnapMail"
      _ -> "User Created"
    end
  end

  defp notes_to_app_name(notes) do
    case notes do
      "Evercam Proxy" -> "recordings"
      "Evercam Thumbnail" -> "thumbnail"
      "Evercam Timelapse" -> "timelapse"
      "Evercam SnapMail" -> "snapmail"
      _ -> "archives"
    end
  end

  defp parse_timestamp(unix_timestamp) do
    unix_timestamp
    |> Calendar.DateTime.Parse.unix!
    |> Calendar.DateTime.to_erl
    |> Calendar.DateTime.from_erl!("Etc/UTC")
  end

  defp not_is_between?(snapshot_date, from, to) do
    snapshot_date = parse_timestamp(snapshot_date)
    !is_after_from?(snapshot_date, from) || !is_before_to?(snapshot_date, to)
  end

  defp is_after_from?(snapshot_date, from) do
    case Calendar.DateTime.diff(snapshot_date, from) do
      {:ok, _seconds, _, :after} -> true
      _ -> false
    end
  end

  defp is_before_to?(snapshot_date, to) do
    case Calendar.DateTime.diff(snapshot_date, to) do
      {:ok, _seconds, _, :before} -> true
      _ -> false
    end
  end

  ######################################
  ## Timelapse functions to save/load ##
  ######################################

  def save_timelapse_metadata(camera_id, timelapse_id, low, medium, high) do
    hackney = [pool: :seaweedfs_upload_pool]
    file_path = "/#{camera_id}/timelapses/#{timelapse_id}/metadata.json"
    url = @seaweedfs <> file_path

    data =
      case HTTPoison.get(url, [], hackney: hackney) do
        {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
          body
          |> Poison.decode!
          |> Map.put("low", low)
          |> Map.put("medium", medium)
          |> Map.put("high", high)
          |> Poison.encode!
        {:ok, %HTTPoison.Response{status_code: 404}} ->
          Poison.encode!(%{low: low, medium: medium, high: high})
        error ->
          raise "Metadata upload at '#{file_path}' failed with: #{inspect error}"
      end
    HTTPoison.post!(url, {:multipart, [{file_path, data, []}]}, [], hackney: hackney)
  end

  def load_timelapse_metadata(camera_id, timelapse_id) do
    file_path = "/#{camera_id}/timelapses/#{timelapse_id}/metadata.json"
    url = @seaweedfs <> file_path

    hackney = [pool: :seaweedfs_download_pool]
    case HTTPoison.get(url, [], hackney: hackney) do
      {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
        Poison.decode!(body)
      {:ok, %HTTPoison.Response{status_code: 404}} ->
        %{}
      error ->
        raise "Metadata download from '#{url}' failed with: #{inspect error}"
    end
  end

  def load_hls_menifiest(camera_exid, timelapse_id, file_name) do
    hackney = [pool: :seaweedfs_download_pool]
    url = "#{@seaweedfs}/#{camera_exid}/timelapses/#{timelapse_id}/ts/#{file_name}"
    case HTTPoison.get(url, [], hackney: hackney) do
      {:ok, %HTTPoison.Response{status_code: 200, body: body}} -> body
      {:ok, %HTTPoison.Response{status_code: 404}} -> nil
      error ->
        raise "Menifiest load at '#{url}' failed with: #{inspect error}"
    end
  end

  def save_hls_files(camera_exid, timelapse_id, file_name) do
    "#{@root_dir}/#{camera_exid}/timelapses/#{timelapse_id}/ts/#{file_name}"
    |> File.open([:read, :binary, :raw], fn(file) -> IO.binread(file, :all) end)
    |> case do
      {:ok, content} -> seaweedfs_save_hls_file(camera_exid, timelapse_id, content, file_name)
      {:error, _error} -> {:error, "Failed to read video file."}
    end
  end

  def seaweedfs_save_hls_file(camera_exid, timelapse_id, content, file_name) do
    hackney = [pool: :seaweedfs_upload_pool]
    file_path = "/#{camera_exid}/timelapses/#{timelapse_id}/ts/#{file_name}"
    post_url = "#{@seaweedfs}#{file_path}"
    case HTTPoison.post(post_url, {:multipart, [{file_path, content, []}]}, [], hackney: hackney) do
      {:ok, _response} -> :noop
      {:error, error} -> Logger.info "[save_hls] [#{camera_exid}] [#{timelapse_id}] [#{inspect error}]"
    end
  end

  def save_timelapse_manifest(camera_id, timelapse_id, content) do
    hackney = [pool: :seaweedfs_upload_pool]
    file_path = "/#{camera_id}/timelapses/#{timelapse_id}/index.m3u8"
    url = @seaweedfs <> file_path

    case HTTPoison.get(url, [], hackney: hackney) do
      {:ok, %HTTPoison.Response{status_code: 200, body: _body}} -> :noop
      _ ->
        HTTPoison.post!(url, {:multipart, [{file_path, content, []}]}, [], hackney: hackney)
    end
  end
end
