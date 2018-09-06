-include("pow.hrl").

-define(PROTOCOL_VERSION, 23).
-define(GENESIS_VERSION, ?PROTOCOL_VERSION).
-define(GENESIS_HEIGHT, 0).
-define(GENESIS_TIME, 0).

-define(BLOCK_HEADER_HASH_BYTES, 32).
-define(TXS_HASH_BYTES, 32).
-define(STATE_HASH_BYTES, 32).
-define(MINER_PUB_BYTES, 32).
-define(BENEFICIARY_PUB_BYTES, 32).
-define(BLOCK_SIGNATURE_BYTES, 64).

-define(KEY_HEADER_TAG, 1).
-define(MICRO_HEADER_TAG, 0).

-define(KEY_HEADER_BYTES, 368).
-define(MIC_HEADER_BYTES, 216).

-type(txs_hash() :: <<_:(?TXS_HASH_BYTES*8)>>).
-type(state_hash() :: <<_:(?STATE_HASH_BYTES*8)>>).
-type(miner_pubkey() :: <<_:(?MINER_PUB_BYTES*8)>>).
-type(beneficiary_pubkey() :: <<_:(?BENEFICIARY_PUB_BYTES*8)>>).
-type(block_header_hash() :: <<_:(?BLOCK_HEADER_HASH_BYTES*8)>>).
-type(block_signature() :: <<_:(?BLOCK_SIGNATURE_BYTES*8)>>).

-type(block_type() :: 'key' | 'micro').

-type(header_binary() :: binary()).
-type(deterministic_header_binary() :: binary()).
