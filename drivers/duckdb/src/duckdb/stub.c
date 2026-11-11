/*
 * Copyright 2026 Leo Cheng
 * SPDX-License-Identifier: Apache-2.0
 *
 * The boundary between MoonBit and DuckDB. The engine is loaded at run time rather than
 * linked at build time: a DuckDB amalgamation is a twenty-megabyte C++ translation unit
 * that takes minutes to compile on every platform and every CI run, and the released
 * shared library is the thing a machine that runs DuckDB already has.
 * `MOONDUCKDB_LIBRARY` names it when the default search does not find it; the error
 * string says so when it does not.
 */

#include <moonbit.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

#ifdef _WIN32
#include <windows.h>
#else
#include <dlfcn.h>
#endif

/* The slice of the DuckDB C API this driver uses, declared here so the stub compiles
 * against nothing but a C compiler: the header is not vendored, and a signature that
 * drifts is caught by the first call. */
typedef struct _duckdb_database *duckdb_database;
typedef struct _duckdb_connection *duckdb_connection;
typedef struct _duckdb_prepared_statement *duckdb_prepared_statement;
typedef uint64_t idx_t;

typedef struct {
  void *internal_ptr;
  idx_t deprecated_column_count;
  idx_t deprecated_row_count;
  idx_t deprecated_rows_changed;
  void *deprecated_columns;
  char *deprecated_error_message;
  void *internal_data;
} duckdb_result;

typedef struct {
  void *data;
  idx_t size;
} duckdb_blob;

typedef enum {
  DUCKDB_TYPE_BOOLEAN = 1,
  DUCKDB_TYPE_TINYINT = 2,
  DUCKDB_TYPE_SMALLINT = 3,
  DUCKDB_TYPE_INTEGER = 4,
  DUCKDB_TYPE_BIGINT = 5,
  DUCKDB_TYPE_UTINYINT = 6,
  DUCKDB_TYPE_USMALLINT = 7,
  DUCKDB_TYPE_UINTEGER = 8,
  DUCKDB_TYPE_UBIGINT = 9,
  DUCKDB_TYPE_FLOAT = 10,
  DUCKDB_TYPE_DOUBLE = 11,
  DUCKDB_TYPE_BLOB = 18
} duckdb_type;

static struct {
  int loaded;
  int (*open)(const char *, duckdb_database *);
  void (*close_db)(duckdb_database *);
  int (*connect)(duckdb_database, duckdb_connection *);
  void (*disconnect)(duckdb_connection *);
  int (*query)(duckdb_connection, const char *, duckdb_result *);
  void (*destroy_result)(duckdb_result *);
  const char *(*result_error)(duckdb_result *);
  idx_t (*rows_changed)(duckdb_result *);
  idx_t (*column_count)(duckdb_result *);
  idx_t (*row_count)(duckdb_result *);
  const char *(*column_name)(duckdb_result *, idx_t);
  duckdb_type (*column_type)(duckdb_result *, idx_t);
  bool (*value_is_null)(duckdb_result *, idx_t, idx_t);
  int64_t (*value_int64)(duckdb_result *, idx_t, idx_t);
  uint64_t (*value_uint64)(duckdb_result *, idx_t, idx_t);
  double (*value_double)(duckdb_result *, idx_t, idx_t);
  bool (*value_boolean)(duckdb_result *, idx_t, idx_t);
  char *(*value_varchar)(duckdb_result *, idx_t, idx_t);
  duckdb_blob (*value_blob)(duckdb_result *, idx_t, idx_t);
  void (*free_mem)(void *);
  int (*prepare)(duckdb_connection, const char *, duckdb_prepared_statement *);
  const char *(*prepare_error)(duckdb_prepared_statement);
  void (*destroy_prepare)(duckdb_prepared_statement *);
  int (*bind_null)(duckdb_prepared_statement, idx_t);
  int (*bind_int64)(duckdb_prepared_statement, idx_t, int64_t);
  int (*bind_double)(duckdb_prepared_statement, idx_t, double);
  int (*bind_boolean)(duckdb_prepared_statement, idx_t, bool);
  int (*bind_varchar)(duckdb_prepared_statement, idx_t, const char *);
  int (*bind_blob)(duckdb_prepared_statement, idx_t, const void *, idx_t);
  int (*execute_prepared)(duckdb_prepared_statement, duckdb_result *);
} api;

static char last_error[1024];

static void set_error(const char *message) {
  snprintf(last_error, sizeof(last_error), "%s", message == NULL ? "" : message);
}

/* A MoonBit byte string is a length and a buffer, not a C string. */
static char *mb_cstr(moonbit_bytes_t bytes) {
  int32_t n = Moonbit_array_length(bytes);
  char *text = (char *)malloc((size_t)n + 1);
  if (text == NULL) {
    return NULL;
  }
  memcpy(text, bytes, (size_t)n);
  text[n] = '\0';
  return text;
}

static moonbit_bytes_t mb_bytes(const void *data, int32_t n) {
  if (data == NULL || n <= 0) {
    return moonbit_make_bytes(0, 0);
  }
  moonbit_bytes_t out = moonbit_make_bytes(n, 0);
  memcpy(out, data, (size_t)n);
  return out;
}

#ifdef _WIN32
static void *sym(HMODULE handle, const char *name) {
  return (void *)GetProcAddress(handle, name);
}
#else
static void *sym(void *handle, const char *name) {
  return dlsym(handle, name);
}
#endif

#define RESOLVE(field, name)                          \
  do {                                                \
    *(void **)(&api.field) = sym(lib, name);          \
    if (api.field == NULL) {                          \
      set_error("the DuckDB library has no " name);   \
      return -1;                                      \
    }                                                 \
  } while (0)

/* Loading is once per process: the engine keeps global state, and a second copy of it
 * in one process is a second copy of its threads and its catalog. */
int32_t moonduckdb_load(void) {
  if (api.loaded) {
    return 0;
  }
#ifdef _WIN32
  HMODULE lib = NULL;
#else
  void *lib = NULL;
#endif
  const char *named = getenv("MOONDUCKDB_LIBRARY");
  if (named != NULL && named[0] != '\0') {
#ifdef _WIN32
    lib = LoadLibraryA(named);
#else
    lib = dlopen(named, RTLD_NOW | RTLD_LOCAL);
#endif
    if (lib == NULL) {
      char buffer[512];
      snprintf(buffer, sizeof(buffer), "cannot load %s", named);
      set_error(buffer);
      return -1;
    }
  }
  if (lib == NULL) {
#ifdef _WIN32
    static const char *names[] = { "duckdb.dll", NULL };
#else
    static const char *names[] = { "libduckdb.so", "libduckdb.so.1", NULL };
#endif
    for (int i = 0; names[i] != NULL; i++) {
#ifdef _WIN32
      lib = LoadLibraryA(names[i]);
#else
      lib = dlopen(names[i], RTLD_NOW | RTLD_LOCAL);
#endif
      if (lib != NULL) {
        break;
      }
    }
  }
  if (lib == NULL) {
    set_error(
      "cannot find the DuckDB library: put libduckdb.so (or duckdb.dll) on the "
      "loader's path, or point MOONDUCKDB_LIBRARY at it");
    return -1;
  }
  RESOLVE(open, "duckdb_open");
  RESOLVE(close_db, "duckdb_close");
  RESOLVE(connect, "duckdb_connect");
  RESOLVE(disconnect, "duckdb_disconnect");
  RESOLVE(query, "duckdb_query");
  RESOLVE(destroy_result, "duckdb_destroy_result");
  RESOLVE(result_error, "duckdb_result_error");
  RESOLVE(rows_changed, "duckdb_rows_changed");
  RESOLVE(column_count, "duckdb_column_count");
  RESOLVE(row_count, "duckdb_row_count");
  RESOLVE(column_name, "duckdb_column_name");
  RESOLVE(column_type, "duckdb_column_type");
  RESOLVE(value_is_null, "duckdb_value_is_null");
  RESOLVE(value_int64, "duckdb_value_int64");
  RESOLVE(value_uint64, "duckdb_value_uint64");
  RESOLVE(value_double, "duckdb_value_double");
  RESOLVE(value_boolean, "duckdb_value_boolean");
  RESOLVE(value_varchar, "duckdb_value_varchar");
  RESOLVE(value_blob, "duckdb_value_blob");
  RESOLVE(free_mem, "duckdb_free");
  RESOLVE(prepare, "duckdb_prepare");
  RESOLVE(prepare_error, "duckdb_prepare_error");
  RESOLVE(destroy_prepare, "duckdb_destroy_prepare");
  RESOLVE(bind_null, "duckdb_bind_null");
  RESOLVE(bind_int64, "duckdb_bind_int64");
  RESOLVE(bind_double, "duckdb_bind_double");
  RESOLVE(bind_boolean, "duckdb_bind_boolean");
  RESOLVE(bind_varchar, "duckdb_bind_varchar");
  RESOLVE(bind_blob, "duckdb_bind_blob");
  RESOLVE(execute_prepared, "duckdb_execute_prepared");
  api.loaded = 1;
  return 0;
}

moonbit_bytes_t moonduckdb_error(void) {
  if (moonduckdb_load() != 0) {
    return mb_bytes(last_error, (int32_t)strlen(last_error));
  }
  return mb_bytes(last_error, (int32_t)strlen(last_error));
}

/* The database handle has to outlive the connection, so both travel in one allocation:
 * [database, connection]. */
int64_t moonduckdb_open(moonbit_bytes_t path) {
  if (moonduckdb_load() != 0) {
    return 0;
  }
  duckdb_database *holder = (duckdb_database *)calloc(1, sizeof(duckdb_database));
  if (holder == NULL) {
    set_error("out of memory");
    return 0;
  }
  char *file = mb_cstr(path);
  int rc = api.open(file, holder);
  free(file);
  if (rc != 0 || *holder == NULL) {
    set_error(last_error[0] != '\0' ? last_error : "cannot open the database");
    free(holder);
    return 0;
  }
  duckdb_connection *conn = (duckdb_connection *)calloc(1, sizeof(duckdb_connection));
  if (conn == NULL || api.connect(*holder, conn) != 0) {
    free(conn);
    api.close_db(holder);
    free(holder);
    set_error("cannot open a connection");
    return 0;
  }
  void **pair = (void **)calloc(2, sizeof(void *));
  if (pair == NULL) {
    api.disconnect(conn);
    free(conn);
    api.close_db(holder);
    free(holder);
    set_error("out of memory");
    return 0;
  }
  pair[0] = holder;
  pair[1] = conn;
  return (int64_t)(intptr_t)pair;
}

/* `pair[1]` is the cell `duckdb_connect` filled in, not the connection it named. */
static duckdb_connection conn_of(void **pair) {
  return *(duckdb_connection *)pair[1];
}

void moonduckdb_close(int64_t handle) {
  void **pair = (void **)(intptr_t)handle;
  if (pair == NULL) {
    return;
  }
  duckdb_connection *conn = (duckdb_connection *)pair[1];
  duckdb_database *db = (duckdb_database *)pair[0];
  if (conn != NULL) {
    api.disconnect(conn);
    free(conn);
  }
  if (db != NULL) {
    api.close_db(db);
    free(db);
  }
  free(pair);
}

/* A statement that returns no rows answers with the number of rows it changed. */
int64_t moonduckdb_exec(int64_t handle, moonbit_bytes_t sql) {
  void **pair = (void **)(intptr_t)handle;
  if (pair == NULL || api.loaded == 0) {
    set_error("the connection is closed");
    return -1;
  }
  duckdb_result result;
  memset(&result, 0, sizeof(result));
  char *text = mb_cstr(sql);
  int rc = api.query(conn_of(pair), text, &result);
  free(text);
  if (rc != 0) {
    const char *message = api.result_error(&result);
    set_error(message != NULL ? message : "statement failed");
    api.destroy_result(&result);
    return -1;
  }
  int64_t changed = (int64_t)api.rows_changed(&result);
  api.destroy_result(&result);
  return changed;
}

int64_t moonduckdb_query(int64_t handle, moonbit_bytes_t sql) {
  void **pair = (void **)(intptr_t)handle;
  if (pair == NULL || api.loaded == 0) {
    set_error("the connection is closed");
    return 0;
  }
  duckdb_result *result = (duckdb_result *)calloc(1, sizeof(duckdb_result));
  if (result == NULL) {
    set_error("out of memory");
    return 0;
  }
  char *text = mb_cstr(sql);
  int rc = api.query(conn_of(pair), text, result);
  free(text);
  if (rc != 0) {
    const char *message = api.result_error(result);
    set_error(message != NULL ? message : "statement failed");
    api.destroy_result(result);
    free(result);
    return 0;
  }
  return (int64_t)(intptr_t)result;
}

moonbit_bytes_t moonduckdb_result_message(int64_t result) {
  duckdb_result *r = (duckdb_result *)(intptr_t)result;
  if (r == NULL) {
    return mb_bytes(last_error, (int32_t)strlen(last_error));
  }
  const char *message = api.result_error(r);
  return mb_bytes(message, message == NULL ? 0 : (int32_t)strlen(message));
}

void moonduckdb_result_close(int64_t result) {
  duckdb_result *r = (duckdb_result *)(intptr_t)result;
  if (r == NULL) {
    return;
  }
  api.destroy_result(r);
  free(r);
}

int32_t moonduckdb_cols(int64_t result) {
  return (int32_t)api.column_count((duckdb_result *)(intptr_t)result);
}

int64_t moonduckdb_rows(int64_t result) {
  return (int64_t)api.row_count((duckdb_result *)(intptr_t)result);
}

moonbit_bytes_t moonduckdb_col_name(int64_t result, int32_t col) {
  const char *name = api.column_name((duckdb_result *)(intptr_t)result, (idx_t)col);
  return mb_bytes(name, name == NULL ? 0 : (int32_t)strlen(name));
}

/* What the value in a cell is, decided by its column's type:
 * 0 NULL, 1 int64, 2 double, 3 bool, 4 text, 5 blob. An unsigned 64-bit value above
 * INT64_MAX becomes text rather than a negative integer. */
int32_t moonduckdb_cell_kind(int64_t result, int32_t col, int64_t row) {
  duckdb_result *r = (duckdb_result *)(intptr_t)result;
  if (api.value_is_null(r, (idx_t)col, (idx_t)row)) {
    return 0;
  }
  switch (api.column_type(r, (idx_t)col)) {
    case DUCKDB_TYPE_BOOLEAN:
      return 3;
    case DUCKDB_TYPE_TINYINT:
    case DUCKDB_TYPE_SMALLINT:
    case DUCKDB_TYPE_INTEGER:
    case DUCKDB_TYPE_BIGINT:
    case DUCKDB_TYPE_UTINYINT:
    case DUCKDB_TYPE_USMALLINT:
    case DUCKDB_TYPE_UINTEGER:
      return 1;
    case DUCKDB_TYPE_UBIGINT:
      return api.value_uint64(r, (idx_t)col, (idx_t)row) > 9223372036854775807ULL
               ? 4
               : 1;
    case DUCKDB_TYPE_FLOAT:
    case DUCKDB_TYPE_DOUBLE:
      return 2;
    case DUCKDB_TYPE_BLOB:
      return 5;
    default:
      return 4;
  }
}

int64_t moonduckdb_cell_int(int64_t result, int32_t col, int64_t row) {
  duckdb_result *r = (duckdb_result *)(intptr_t)result;
  if (api.column_type(r, (idx_t)col) == DUCKDB_TYPE_UBIGINT) {
    return (int64_t)api.value_uint64(r, (idx_t)col, (idx_t)row);
  }
  return api.value_int64(r, (idx_t)col, (idx_t)row);
}

double moonduckdb_cell_double(int64_t result, int32_t col, int64_t row) {
  duckdb_result *r = (duckdb_result *)(intptr_t)result;
  if (api.column_type(r, (idx_t)col) == DUCKDB_TYPE_FLOAT) {
    return (double)(float)api.value_double(r, (idx_t)col, (idx_t)row);
  }
  return api.value_double(r, (idx_t)col, (idx_t)row);
}

int32_t moonduckdb_cell_bool(int64_t result, int32_t col, int64_t row) {
  return api.value_boolean((duckdb_result *)(intptr_t)result, (idx_t)col, (idx_t)row)
    ? 1
    : 0;
}

/* Text and blob cells are copied into a MoonBit-managed buffer and the engine's copy is
 * released, so a caller never holds memory it cannot free. */
moonbit_bytes_t moonduckdb_cell_text(int64_t result, int32_t col, int64_t row) {
  char *text = api.value_varchar((duckdb_result *)(intptr_t)result, (idx_t)col, (idx_t)row);
  if (text == NULL) {
    return moonbit_make_bytes(0, 0);
  }
  moonbit_bytes_t bytes = mb_bytes(text, (int32_t)strlen(text));
  api.free_mem(text);
  return bytes;
}

moonbit_bytes_t moonduckdb_cell_blob(int64_t result, int32_t col, int64_t row) {
  duckdb_blob blob = api.value_blob((duckdb_result *)(intptr_t)result, (idx_t)col, (idx_t)row);
  if (blob.data == NULL) {
    return moonbit_make_bytes(0, 0);
  }
  moonbit_bytes_t bytes = mb_bytes(blob.data, (int32_t)blob.size);
  api.free_mem(blob.data);
  return bytes;
}

int64_t moonduckdb_prepare(int64_t handle, moonbit_bytes_t sql) {
  void **pair = (void **)(intptr_t)handle;
  if (pair == NULL || api.loaded == 0) {
    set_error("the connection is closed");
    return 0;
  }
  duckdb_prepared_statement *stmt =
    (duckdb_prepared_statement *)calloc(1, sizeof(duckdb_prepared_statement));
  if (stmt == NULL) {
    set_error("out of memory");
    return 0;
  }
  char *text = mb_cstr(sql);
  int rc = api.prepare(conn_of(pair), text, stmt);
  free(text);
  if (rc != 0 || *stmt == NULL) {
    const char *message = api.prepare_error(*stmt);
    set_error(message != NULL ? message : "prepare failed");
    api.destroy_prepare(stmt);
    free(stmt);
    return 0;
  }
  return (int64_t)(intptr_t)stmt;
}

int32_t moonduckdb_bind(int64_t prepared, int32_t index, int32_t kind, int64_t i,
                        double d, int32_t b, moonbit_bytes_t bytes) {
  if (prepared == 0) {
    return -1;
  }
  duckdb_prepared_statement stmt = *(duckdb_prepared_statement *)(intptr_t)prepared;
  switch (kind) {
    case 0:
      return api.bind_null(stmt, (idx_t)index);
    case 1:
      return api.bind_int64(stmt, (idx_t)index, i);
    case 2:
      return api.bind_double(stmt, (idx_t)index, d);
    case 3:
      return api.bind_boolean(stmt, (idx_t)index, b != 0);
    case 4: {
      char *text = mb_cstr(bytes);
      int rc = api.bind_varchar(stmt, (idx_t)index, text == NULL ? "" : text);
      free(text);
      return rc;
    }
    case 5:
      return api.bind_blob(stmt, (idx_t)index, bytes, (idx_t)Moonbit_array_length(bytes));
    default:
      return -1;
  }
}

moonbit_bytes_t moonduckdb_prepare_message(int64_t prepared) {
  if (prepared == 0) {
    return mb_bytes(last_error, (int32_t)strlen(last_error));
  }
  const char *message =
    api.prepare_error(*(duckdb_prepared_statement *)(intptr_t)prepared);
  return mb_bytes(message, message == NULL ? 0 : (int32_t)strlen(message));
}

void moonduckdb_prepare_close(int64_t prepared) {
  duckdb_prepared_statement *stmt = (duckdb_prepared_statement *)(intptr_t)prepared;
  if (stmt == NULL) {
    return;
  }
  api.destroy_prepare(stmt);
  free(stmt);
}

int64_t moonduckdb_exec_prepared(int64_t prepared) {
  if (prepared == 0) {
    set_error("the statement is closed");
    return -1;
  }
  duckdb_prepared_statement stmt = *(duckdb_prepared_statement *)(intptr_t)prepared;
  duckdb_result result;
  memset(&result, 0, sizeof(result));
  if (api.execute_prepared(stmt, &result) != 0) {
    const char *message = api.result_error(&result);
    set_error(message != NULL ? message : "statement failed");
    api.destroy_result(&result);
    return -1;
  }
  int64_t changed = (int64_t)api.rows_changed(&result);
  api.destroy_result(&result);
  return changed;
}

int64_t moonduckdb_query_prepared(int64_t prepared) {
  if (prepared == 0) {
    set_error("the statement is closed");
    return 0;
  }
  duckdb_prepared_statement stmt = *(duckdb_prepared_statement *)(intptr_t)prepared;
  duckdb_result *result = (duckdb_result *)calloc(1, sizeof(duckdb_result));
  if (result == NULL) {
    set_error("out of memory");
    return 0;
  }
  if (api.execute_prepared(stmt, result) != 0) {
    const char *message = api.result_error(result);
    set_error(message != NULL ? message : "statement failed");
    api.destroy_result(result);
    free(result);
    return 0;
  }
  return (int64_t)(intptr_t)result;
}
