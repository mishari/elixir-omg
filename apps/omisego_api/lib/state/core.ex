defmodule OmiseGO.API.State.Core do
  @moduledoc """
  Functional core for State.
  """

  # this `use` generates OmiseGO.API.State.CoreGS module:
  # TODO: rework macro so it can be called from test code only
  use OmiseGO.API.BlackBoxMe

  require Logger

  @maximum_block_size 65_536

  defstruct [:height, :last_deposit_height, :utxos, pending_txs: [], tx_index: 0]

  alias OmiseGO.API.Block
  alias OmiseGO.API.State.Core
  alias OmiseGO.API.State.Transaction

  @type deposit() :: %{
          blknum: pos_integer(),
          currency: <<_::160>>,
          owner: <<_::160>>,
          amount: pos_integer()
        }
  @type utxo() :: term()
  @type side_effects() :: term()

  @type exec_error ::
          :cant_spend_zero_utxo
          | :incorrect_spender
          | :incorrect_currency
          | :amounts_dont_add_up
          | :invalid_current_block_number
          | :utxo_not_found

  def extract_initial_state(
        utxos_query_result,
        height_query_result,
        last_deposit_height_query_result,
        child_block_interval
      ) do
    # extract height, last deposit height and utxos from query result
    height = height_query_result + child_block_interval

    utxos = Enum.reduce(utxos_query_result, %{}, &Map.merge/2)

    state = %__MODULE__{
      height: height,
      last_deposit_height: last_deposit_height_query_result,
      utxos: utxos
    }

    {:ok, state}
  end

  @doc """
  Includes the transaction into the state when valid, rejects otherwise.

  NOTE that tx is assumed to have distinct inputs, that should be checked in prior state-less validation
  """
  @spec exec(tx :: %Transaction.Recovered{}, fees :: map(), state :: %Core{}) ::
          {:ok, {Transaction.Recovered.signed_tx_hash_t(), pos_integer, pos_integer}, %Core{}}
          | {{:error, exec_error}, %Core{}}
  def exec(
        %Transaction.Recovered{
          signed_tx: %Transaction.Signed{
            raw_tx: raw_tx = %Transaction{amount1: amount1, amount2: amount2, cur12: currency}
          },
          spender1: spender1,
          spender2: spender2
        } = recovered_tx,
        fees,
        state
      ) do
    # for now just 1 currency supported
    fee = fees[currency]

    with :ok <- validate_block_size(state),
         {:ok, in_amount1} <- correct_input_in_position?(1, state, raw_tx, spender1),
         {:ok, in_amount2} <- correct_input_in_position?(2, state, raw_tx, spender2),
         :ok <- amounts_add_up?(in_amount1 + in_amount2, amount1 + amount2 + fee) do
      {:ok, {recovered_tx.signed_tx_hash, state.height, state.tx_index},
       state
       |> apply_spend(raw_tx)
       |> add_pending_tx(recovered_tx)}
    else
      {:error, _reason} = error -> {error, state}
    end
  end

  defp add_pending_tx(%Core{pending_txs: pending_txs, tx_index: tx_index} = state, new_tx) do
    %Core{
      state
      | tx_index: tx_index + 1,
        pending_txs: [new_tx | pending_txs]
    }
  end

  # if there's no spender, make sure we cannot spend, but everything's valid
  defp correct_input_in_position?(_, _, _, nil), do: {:ok, 0}

  defp correct_input_in_position?(
         1,
         state,
         %Transaction{blknum1: blknum, txindex1: txindex, oindex1: oindex, cur12: spent_cur},
         spender
       ) do
    check_utxo_and_extract_amount(state, {blknum, txindex, oindex}, spender, spent_cur)
  end

  defp correct_input_in_position?(
         2,
         state,
         %Transaction{blknum2: blknum, txindex2: txindex, oindex2: oindex, cur12: spent_cur},
         spender
       ) do
    check_utxo_and_extract_amount(state, {blknum, txindex, oindex}, spender, spent_cur)
  end

  defp check_utxo_and_extract_amount(%Core{utxos: utxos}, {blknum, txindex, oindex}, spender, spent_cur) do
    with {:ok, %{owner: owner, currency: cur, amount: owner_has}} <- get_utxo(utxos, {blknum, txindex, oindex}),
         :ok <- is_spender?(owner, spender),
         :ok <- same_currency?(cur, spent_cur),
         do: {:ok, owner_has}
  end

  defp get_utxo(_utxos, {0, 0, 0}), do: {:error, :cant_spend_zero_utxo}

  defp get_utxo(utxos, {blknum, txindex, oindex}) do
    case Map.get(utxos, {blknum, txindex, oindex}) do
      nil -> {:error, :utxo_not_found}
      found -> {:ok, found}
    end
  end

  defp is_spender?(owner, spender) do
    if owner == spender, do: :ok, else: {:error, :incorrect_spender}
  end

  defp same_currency?(utxo_currency, spent_currency) do
    if utxo_currency == spent_currency, do: :ok, else: {:error, :incorrect_currency}
  end

  # fee is implicit - it's the difference between funds owned and spend
  defp amounts_add_up?(has, spends) do
    if has >= spends, do: :ok, else: {:error, :amounts_dont_add_up}
  end

  defp apply_spend(
         %Core{height: height, tx_index: tx_index, utxos: utxos} = state,
         %Transaction{
           blknum1: blknum1,
           txindex1: txindex1,
           oindex1: oindex1,
           blknum2: blknum2,
           txindex2: txindex2,
           oindex2: oindex2
         } = tx
       ) do
    new_utxos_map =
      tx
      |> non_zero_utxos_from(height, tx_index)
      |> Map.new()

    %Core{
      state
      | utxos:
          utxos
          |> Map.delete({blknum1, txindex1, oindex1})
          |> Map.delete({blknum2, txindex2, oindex2})
          |> Map.merge(new_utxos_map)
    }
  end

  defp non_zero_utxos_from(%Transaction{} = tx, height, tx_index) do
    tx
    |> utxos_from(height, tx_index)
    |> Enum.filter(fn {_key, value} -> is_non_zero_amount?(value) end)
  end

  defp utxos_from(%Transaction{} = tx, height, tx_index) do
    [
      {{height, tx_index, 0}, %{owner: tx.newowner1, currency: tx.cur12, amount: tx.amount1}},
      {{height, tx_index, 1}, %{owner: tx.newowner2, currency: tx.cur12, amount: tx.amount2}}
    ]
  end

  defp is_non_zero_amount?(%{amount: 0}), do: false
  defp is_non_zero_amount?(%{amount: _}), do: true

  @doc """
   - Generates block and calculates it's root hash for submission
   - generates triggers for events
   - generates requests to the persistence layer for a block
   - processes pending txs gathered, updates height etc
  """
  @spec form_block(pos_integer(), state :: %Core{}) :: {:ok, side_effects(), new_state :: %Core{}}
  def form_block(child_block_interval, %Core{pending_txs: reverse_txs, height: height} = state) do
    txs = Enum.reverse(reverse_txs)

    block =
      txs
      |> Block.hashed_txs_at(height)

    event_triggers =
      txs
      |> Enum.map(fn tx -> %{tx: tx} end)

    db_updates_new_utxos =
      txs
      |> Enum.with_index()
      |> Enum.flat_map(fn {%Transaction.Recovered{signed_tx: %Transaction.Signed{raw_tx: tx}}, tx_idx} ->
        non_zero_utxos_from(tx, height, tx_idx)
      end)
      |> Enum.map(&utxo_to_db_put/1)

    db_updates_spent_utxos =
      txs
      |> Enum.flat_map(fn %Transaction.Recovered{signed_tx: %Transaction.Signed{raw_tx: tx}} ->
        [{tx.blknum1, tx.txindex1, tx.oindex1}, {tx.blknum2, tx.txindex2, tx.oindex2}]
      end)
      |> Enum.filter(fn utxo_key -> utxo_key != {0, 0, 0} end)
      |> Enum.map(fn utxo_key -> {:delete, :utxo, utxo_key} end)

    db_updates_block = [{:put, :block, block}]

    db_updates_top_block_number = [{:put, :child_top_block_number, height}]

    db_updates =
      [db_updates_new_utxos, db_updates_spent_utxos, db_updates_block, db_updates_top_block_number]
      |> Enum.concat()

    new_state = %Core{
      state
      | tx_index: 0,
        height: height + child_block_interval,
        pending_txs: []
    }

    {:ok, {block, event_triggers, db_updates}, new_state}
  end

  def decode_deposit(%{owner: owner, currency: currency} = deposit) do
    %{deposit | owner: decode_address(owner), currency: decode_address(currency)}
  end

  defp decode_address(<<"0x", hex_encoded::binary-size(40)>>) do
    decode_address(hex_encoded)
  end

  defp decode_address(<<hex_encoded::binary-size(40)>>) do
    Base.decode16!(hex_encoded, case: :lower)
  end

  defp decode_address(<<raw::binary-size(20)>>) do
    raw
  end

  @spec deposit(deposits :: [deposit()], state :: %Core{}) :: {:ok, side_effects(), new_state :: %Core{}}
  def deposit(deposits, %Core{utxos: utxos, last_deposit_height: last_deposit_height} = state) do
    deposits = deposits |> Enum.filter(&(&1.blknum > last_deposit_height))

    new_utxos =
      deposits
      |> Enum.map(&deposit_to_utxo/1)

    event_triggers =
      deposits
      |> Enum.map(fn %{owner: owner, amount: amount} -> %{deposit: %{amount: amount, owner: owner}} end)

    last_deposit_height = get_last_deposit_height(deposits, last_deposit_height)

    db_updates_new_utxos =
      new_utxos
      |> Enum.map(&utxo_to_db_put/1)

    db_updates = db_updates_new_utxos ++ last_deposit_height_db_update(deposits, last_deposit_height)

    new_state = %Core{
      state
      | utxos: Map.merge(utxos, Map.new(new_utxos)),
        last_deposit_height: last_deposit_height
    }

    log_deposits(deposits)

    {:ok, {event_triggers, db_updates}, new_state}
  end

  defp log_deposits([]), do: :ok
  defp log_deposits(deposits), do: _ = Logger.info(fn -> "Recognized deposits: #{inspect(deposits)}" end)

  defp utxo_to_db_put({utxo_position, utxo}), do: {:put, :utxo, %{utxo_position => utxo}}

  defp deposit_to_utxo(%{blknum: blknum, currency: cur, owner: owner, amount: amount}) do
    {{blknum, 0, 0}, %{amount: amount, currency: cur, owner: owner}}
  end

  defp get_last_deposit_height(deposits, current_height) do
    if Enum.empty?(deposits) do
      current_height
    else
      deposits
      |> Enum.max_by(& &1.blknum)
      |> Map.get(:blknum)
    end
  end

  defp last_deposit_height_db_update(deposits, last_deposit_height) do
    if Enum.empty?(deposits) do
      []
    else
      [{:put, :last_deposit_block_height, last_deposit_height}]
    end
  end

  defp validate_block_size(%__MODULE__{tx_index: number_of_transactions_in_block}) do
    case number_of_transactions_in_block == @maximum_block_size do
      true -> {:error, :too_many_transactions_in_block}
      false -> :ok
    end
  end

  @doc """
  Spends exited utxos
  """
  @spec exit_utxos(exiting_utxos :: [utxo()], state :: %Core{}) :: {:ok, side_effects(), new_state :: %Core{}}
  def exit_utxos(exiting_utxos, %Core{utxos: utxos} = state) do
    exiting_utxos =
      exiting_utxos
      |> Enum.filter(fn %{blknum: blknum, txindex: txindex, oindex: oindex} ->
        Map.has_key?(utxos, {blknum, txindex, oindex})
      end)

    event_triggers =
      exiting_utxos
      |> Enum.map(fn %{owner: owner, blknum: blknum, txindex: txindex, oindex: oindex} ->
        %{exit: %{owner: owner, blknum: blknum, txindex: txindex, oindex: oindex}}
      end)

    state =
      exiting_utxos
      |> Enum.reduce(state, fn %{blknum: blknum, txindex: txindex, oindex: oindex}, state ->
        %{state | utxos: Map.delete(state.utxos, {blknum, txindex, oindex})}
      end)

    deletes =
      exiting_utxos
      |> Enum.map(fn %{blknum: blknum, txindex: txindex, oindex: oindex} ->
        {:delete, :utxo, {blknum, txindex, oindex}}
      end)

    {:ok, {event_triggers, deletes}, state}
  end

  @doc """
  Checks if utxo exists
  """
  @spec utxo_exists(utxo(), %Core{}) :: :utxo_exists | :utxo_does_not_exist
  def utxo_exists(%{blknum: blknum, txindex: txindex, oindex: oindex}, %Core{utxos: utxos}) do
    case Map.has_key?(utxos, {blknum, txindex, oindex}) do
      true -> :utxo_exists
      false -> :utxo_does_not_exist
    end
  end

  @doc """
  Gets the current block's height
  """
  @spec get_current_child_block_height(%__MODULE__{}) :: pos_integer
  def get_current_child_block_height(%{height: height}), do: height
end
