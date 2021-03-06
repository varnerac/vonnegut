%%
-module(vg_active_segment).

-behaviour(gen_server).

-export([start_link/3,
         write/3,
         write/4,
         halt/2,
         tail/3,
         where/2,
         stop_indexing/2,
         resume_indexing/2]).

-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-include("vg.hrl").

-record(config, {log_dir              :: file:filename(),
                 segment_bytes        :: integer(),
                 index_max_bytes      :: integer(),
                 index_interval_bytes :: integer()}).

-record(state, {topic_dir      :: file:filename(),
                next_id        :: integer(),
                next_brick     :: atom(),
                byte_count     :: integer(),
                pos            :: integer(),
                index_pos      :: integer(),
                log_fd         :: file:fd(),
                segment_id     :: integer(),
                index_fd       :: file:fd() | undefined,
                topic          :: binary(),
                partition      :: integer(),
                config         :: #config{},
                halted = false :: boolean(),
                index = true   :: boolean(),
                tailer         :: pid() | undefined
               }).

%% need this until an Erlang release with `hibernate_after` spec added to gen option type
-dialyzer({nowarn_function, start_link/3}).

-define(ACTIVE_SEG(Topic, Partition), {via, gproc, {n, l, {active, Topic, Partition}}}).

start_link(Topic, Partition, NextBrick) ->
    case gen_server:start_link(?ACTIVE_SEG(Topic, Partition), ?MODULE, [Topic, Partition, NextBrick],
                               [{hibernate_after, timer:minutes(5)}]) of % hibernate after 5 minutes with no messages
        {ok, Pid} ->
            {ok, Pid};
        {error, {already_started, Pid}} ->
            {ok, Pid};
        {error, Reason} ->
            {error, Reason}
    end.

-spec write(Topic, Partition, RecordBatch) -> {ok, Offset} | {error, any()} when
      Topic :: binary(),
      Partition :: integer(),
      RecordBatch :: vg:record_batch() | [vg:record_batch()],
      Offset :: integer().
write(Topic, Partition, RecordBatch) ->
    write(Topic, Partition, head, RecordBatch).

write(Topic, Partition, ExpectedId, [RecordBatch]) ->
    write_(Topic, Partition, ExpectedId, RecordBatch);
write(Topic, Partition, ExpectedId, RecordBatch) ->
    write_(Topic, Partition, ExpectedId, RecordBatch).

write_(Topic, Partition, ExpectedId, RecordBatch) ->
    try
        case gen_server:call(?ACTIVE_SEG(Topic, Partition), {write, ExpectedId, RecordBatch}) of
            retry ->
                write_(Topic, Partition, ExpectedId, RecordBatch);
            R -> R
        end
    catch _:{noproc, _} ->
            create_retry(Topic, Partition, ExpectedId, RecordBatch);
          error:badarg ->  %% is this too broad?  how to restrict?
            create_retry(Topic, Partition, ExpectedId, RecordBatch);
          exit:{timeout, _} ->
            {error, timeout}
    end.

create_retry(Topic, Partition, ExpectedId, RecordBatch)->
    lager:warning("write to nonexistent topic '~s', creating", [Topic]),
    {ok, _} = vg_cluster_mgr:ensure_topic(Topic),
    write_(Topic, Partition, ExpectedId, RecordBatch).

halt(Topic, Partition) ->
    gen_server:call(?ACTIVE_SEG(Topic, Partition), halt).

tail(Topic, Partition, Printer) ->
    gen_server:call(?ACTIVE_SEG(Topic, Partition), {tail, Printer}).

where(Topic, Partition) ->
    {_, _, Where} = ?ACTIVE_SEG(Topic, Partition),
    gproc:where(Where).

stop_indexing(Topic, Partition) ->
    gen_server:call(?ACTIVE_SEG(Topic, Partition), stop_indexing).

resume_indexing(Topic, Partition) ->
    gen_server:call(?ACTIVE_SEG(Topic, Partition), resume_indexing).

%%%%%%%%%%%%

init([Topic, Partition, NextNode]) ->
    lager:info("at=init topic=~p next_server=~p", [Topic, NextNode]),
    Config = setup_config(),
    Partition = 0,
    LogDir = Config#config.log_dir,
    TopicDir = filename:join(LogDir, [binary_to_list(Topic), "-", integer_to_list(Partition)]),
    filelib:ensure_dir(filename:join(TopicDir, "ensure")),

    vg_log_segments:load_all(Topic, Partition),

    {Id, LatestIndex, LatestLog} = vg_log_segments:find_latest_id(TopicDir, Topic, Partition),
    LastLogId = filename:basename(LatestLog, ".log"),
    {ok, LogFD} = vg_utils:open_append(LatestLog),
    {ok, IndexFD} = vg_utils:open_append(LatestIndex),

    {ok, Position} = file:position(LogFD, eof),
    {ok, IndexPosition} = file:position(IndexFD, eof),

    vg_topics:insert_hwm(Topic, Partition, Id),

    {ok, #state{next_id = Id + 1,
                next_brick = NextNode,
                topic_dir = TopicDir,
                byte_count = 0,
                pos = Position,
                index_pos = IndexPosition,
                log_fd = LogFD,
                segment_id = list_to_integer(LastLogId),
                index_fd = IndexFD,
                topic = Topic,
                partition = Partition,
                config = Config
               }}.

%% coverall to keep any new writes from coming in while we delete the topic
handle_call(_Msg, _From, State = #state{halted = true}) ->
    {reply, halted, State};
handle_call(halt, _From, State) ->
    {reply, ok, State#state{halted = true}};
handle_call({tail, Printer}, _From, State) ->
    monitor(process, Printer),
    {reply, ok, State#state{tailer = Printer}};
handle_call(stop_indexing, _From, #state{index_fd = undefined} = State) ->
    {reply, ok, State#state{index = false}};
handle_call(stop_indexing, _From, #state{index_fd = FD} = State) ->
    %% no need to sync here, we're about to unlink
    file:close(FD),
    {reply, ok, State#state{index = false, index_fd = undefined}};
handle_call(resume_indexing, _From, State) ->
    {reply, ok, State#state{index = true}};
handle_call({write, ExpectedID0, Record=#{last_offset_delta := LastOffsetDelta,
                                          record_batch := RecordBatch}}, _From, State=#state{next_id=ID,
                                                                                             tailer=Tailer,
                                                                                             topic=Topic,
                                                                                             next_brick=NextBrick}) ->
    %% TODO: add pipelining of requests
    try
        ExpectedID =
            case ExpectedID0 of
                head ->
                    ID + LastOffsetDelta + 1;
                Supplied when is_integer(Supplied) ->
                    case (ID + LastOffsetDelta + 1) == Supplied of
                        true ->
                            ExpectedID0;
                        %% should we check > vs < here?  one is repair
                        %% the other is bad corruption
                        _ ->
                            %% inferred current id of the writing segment
                            WriterID = ExpectedID0 - LastOffsetDelta,
                            %% this should probably be limited, if
                            %% we're going back too far, we need to be
                            %% in some sort of catch-up mode
                            lager:debug("starting write repair, ~p", [WriterID]),
                            WriteRepairSet = write_repair(WriterID, State),
                            throw({write_repair, WriteRepairSet, State})
                    end
            end,

        Result =
            case NextBrick of
                Role when Role == solo; Role == tail -> proceed;
                _ ->
                    (fun Loop(_, Remaining) when Remaining =< 0 ->
                             {error, timeout};
                         Loop(Start, Remaining) ->
                             case vg_client:replicate(next_brick, Topic, ExpectedID, RecordBatch, Remaining) of
                                 retry ->
                                     Now = erlang:monotonic_time(milli_seconds),
                                     Elapsed = Now - Start,
                                     Loop(Now, Remaining - Elapsed);
                                 Result ->
                                     Result
                             end
                     end)(erlang:monotonic_time(milli_seconds), timeout() * 5)
            end,

        case Result of
            Go when Go =:= proceed orelse
                    element(1, Go) =:= ok ->
                State1 = write_record_batch(Record, State),
                case Tailer of
                    undefined ->
                        ok;
                    Pid ->
                        Pid ! {'$print', {State1#state.next_id - 1, Record}}
                end,
                {reply, {ok, State1#state.next_id - 1}, State1};
            {write_repair, RepairSet} ->
                prometheus_counter:inc(write_repairs),
                %% add in the following when pipelining is added, if it makes sense
                %% prometheus_gauge:inc(pending_write_repairs, length(RepairSet)),
                State1 = write_record_batch(RepairSet, State),
                case ExpectedID0 of
                    head ->
                        {reply, retry, State1};
                    _ ->
                        {reply, {write_repair, RepairSet}, State1}
                end;
            {error, Reason} ->
                {reply, {error, Reason}, State}
        end
    catch throw:{write_repair, RS, S} ->
            {reply, {write_repair, RS}, S};
          throw:{E, S} ->
            {reply, {error, E}, S}
    end;
handle_call(_Msg, _From, State) ->
    lager:info("bad call ~p ~p", [_Msg, _From]),
    {noreply, State}.

handle_cast(_Msg, State) ->
    lager:info("bad cast ~p", [_Msg]),
    {noreply, State}.

handle_info({'DOWN', _MonitorRef, _Type, _Object, _Info}, State) ->
    {noreply, State#state{tailer = undefined}};
handle_info(_, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_, State, _) ->
    {ok, State}.

%%

write_record_batch(Batches, State) when is_list(Batches) ->
    lists:foldl(fun(Batch, StateAcc) ->
                        write_record_batch(Batch, StateAcc)
                end, State, Batches);
write_record_batch(#{last_offset_delta := LastOffsetDelta,
                     size := Size0,
                     record_batch := Bytes}, State=#state{topic=Topic,
                                                          partition=Partition,
                                                          next_id=Id,
                                                          byte_count=ByteCount}) ->
    Size = Size0 + ?OFFSET_AND_LENGTH_BYTES,
    NextId = Id + LastOffsetDelta + 1,
    State1 = #state{pos=Position1,
                    log_fd=LogFile} = maybe_roll(Size, State),

    %% write to log
    ok = file:write(LogFile, [<<Id:64/signed-integer, Size0:32/signed-integer>>, Bytes]),
    State2 = State1#state{byte_count=ByteCount+Size},

    %% maybe write index entry
    State3 = update_index(State2),

    %% update highwatermark in ets table
    vg_topics:update_hwm(Topic, Partition, NextId-1),

    State3#state{next_id=NextId,
                 pos=Position1+Size}.

%% Create new log segment and index file if current segment is too large
%% or if the index file is over its max and would be written to again.
maybe_roll(Size, State=#state{next_id=Id,
                              topic_dir=TopicDir,
                              log_fd=LogFile,
                              index_fd=IndexFile,
                              pos=Position,
                              byte_count=ByteCount,
                              index_pos=IndexPosition,
                              index = Indexing,
                              topic=Topic,
                              partition=Partition,
                              config=#config{segment_bytes=SegmentBytes,
                                             index_max_bytes=IndexMaxBytes,
                                             index_interval_bytes=IndexIntervalBytes}})
  when Position+Size > SegmentBytes
     orelse (ByteCount+Size >= IndexIntervalBytes
            andalso IndexPosition+?INDEX_ENTRY_SIZE > IndexMaxBytes) ->
    lager:debug("seg size ~p max size ~p", [Position+Size, SegmentBytes]),
    lager:debug("index interval size ~p max size ~p", [ByteCount+Size, IndexIntervalBytes]),
    lager:debug("index pos ~p max size ~p", [IndexPosition+?INDEX_ENTRY_SIZE, IndexMaxBytes]),
    ok = file:sync(LogFile),
    ok = file:close(LogFile),

    case Indexing of
        true ->
            ok = file:sync(IndexFile),
            ok = file:close(IndexFile);
        _ ->
            ok
    end,

    {NewIndexFile, NewLogFile} = vg_log_segments:new_index_log_files(TopicDir, Id),
    vg_log_segments:insert(Topic, Partition, Id),

    State#state{log_fd=NewLogFile,
                index_fd=NewIndexFile,
                %% we assume here that new indexes are good, and
                %% re-enable writing, expecting the old indexes to
                %% catch up eventually.  This might be racy
                index = true,
                segment_id = Id,
                byte_count=0,
                pos=0,
                index_pos=0};
maybe_roll(_, State) ->
    State.

%% skip writing indexes if they're disabled.
update_index(State=#state{index = false}) ->
    State;
%% Add to index if the number of bytes written to the log since the last index record was written
update_index(State=#state{next_id=Id,
                          pos=Position,
                          index_fd=IndexFile,
                          byte_count=ByteCount,
                          index_pos=IndexPosition,
                          segment_id=BaseOffset,
                          config=#config{index_interval_bytes=IndexIntervalBytes}})
  when ByteCount >= IndexIntervalBytes ->
    IndexEntry = <<(Id - BaseOffset):?INDEX_OFFSET_BITS/unsigned, Position:?INDEX_OFFSET_BITS/unsigned>>,
    ok = file:write(IndexFile, IndexEntry),
    State#state{index_pos=IndexPosition+?INDEX_ENTRY_SIZE,
                byte_count=0};
update_index(State) ->
    State.

write_repair(Start, #state{next_id = ID, topic = Topic, partition = Partition} = _State) ->
    %% two situations: replaying single-segment writes, and writes
    %% that span multiple segments
    {StartSegmentID, {StartPosition, _}} = vg_log_segments:find_segment_offset(Topic, Partition, Start),
    {EndSegmentID, {EndPosition, EndSize}} = vg_log_segments:find_segment_offset(Topic, Partition, ID),
    File = vg_utils:log_file(Topic, Partition, StartSegmentID),
    lager:debug("at=write_repair file=~p start=~p end=~p", [File, StartPosition, EndPosition]),
    case StartSegmentID == EndSegmentID of
        true ->
            {ok, FD} = file:open(File, [read, binary, raw]),
            try
                {ok, Data} = file:pread(FD, StartPosition, (EndPosition + EndSize) - StartPosition),
                [{StartSegmentID, Data}]
            after
                file:close(FD)
            end;
        _ ->
            error(not_implemented)
    end.

setup_config() ->
    {ok, [LogDir]} = application:get_env(vonnegut, log_dirs),
    {ok, SegmentBytes} = application:get_env(vonnegut, segment_bytes),
    {ok, IndexMaxBytes} = application:get_env(vonnegut, index_max_bytes),
    {ok, IndexIntervalBytes} = application:get_env(vonnegut, index_interval_bytes),
    #config{log_dir=LogDir,
            segment_bytes=SegmentBytes,
            index_max_bytes=IndexMaxBytes,
            index_interval_bytes=IndexIntervalBytes}.

timeout() ->
    application:get_env(vonnegut, ack_timeout, 1000).
