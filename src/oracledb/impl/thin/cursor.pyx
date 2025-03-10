#------------------------------------------------------------------------------
# Copyright (c) 2020, 2022, Oracle and/or its affiliates.
#
# This software is dual-licensed to you under the Universal Permissive License
# (UPL) 1.0 as shown at https://oss.oracle.com/licenses/upl and Apache License
# 2.0 as shown at http://www.apache.org/licenses/LICENSE-2.0. You may choose
# either license.
#
# If you elect to accept the software under the Apache License, Version 2.0,
# the following applies:
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#------------------------------------------------------------------------------

#------------------------------------------------------------------------------
# cursor.pyx
#
# Cython file defining the thin Cursor implementation class (embedded in
# thin_impl.pyx).
#------------------------------------------------------------------------------

cdef class ThinCursorImpl(BaseCursorImpl):

    cdef:
        ThinConnImpl _conn_impl
        Statement _statement
        list _batcherrors
        list _dmlrowcounts
        list _implicit_resultsets
        uint32_t _num_columns
        uint32_t _last_row_index
        Rowid _lastrowid

    def __cinit__(self, conn_impl):
        self._conn_impl = conn_impl

    cdef int _close(self, bint in_del) except -1:
        if self._statement is not None:
            self._conn_impl._return_statement(self._statement)
            self._statement = None

    cdef BaseVarImpl _create_var_impl(self, object conn):
        cdef ThinVarImpl var_impl
        var_impl = ThinVarImpl.__new__(ThinVarImpl)
        var_impl._conn_impl = self._conn_impl
        return var_impl

    cdef MessageWithData _create_message(self, type typ, object cursor):
        """
        Creates a message object that is used to send a request to the database
        and receive back its response.
        """
        cdef MessageWithData message
        message = typ.__new__(typ, cursor, self)
        message._initialize(self._conn_impl)
        message.cursor = cursor
        message.cursor_impl = self
        return message

    @cython.boundscheck(False)
    @cython.wraparound(False)
    cdef int _create_fetch_var(self, object conn, object cursor,
                               object type_handler, ssize_t pos,
                               FetchInfo fetch_info) except -1:
        """
        Internal method that creates a fetch variable. A check is made after
        the variable is created to determine if a conversion is required and
        therefore a define must be performed.
        """
        cdef:
            ThinDbObjectTypeImpl typ_impl
            ThinVarImpl var_impl
        BaseCursorImpl._create_fetch_var(self, conn, cursor, type_handler, pos,
                                         fetch_info)
        var_impl = self.fetch_var_impls[pos]
        if var_impl.dbtype._ora_type_num != fetch_info._dbtype._ora_type_num:
            conversion_helper(var_impl, fetch_info,
                              &self._statement._requires_define)
        elif not self._statement._requires_define \
                and fetch_info._dbtype._ora_type_num in \
                        (TNS_DATA_TYPE_BLOB, TNS_DATA_TYPE_CLOB):
            self._statement._requires_define = True
        elif var_impl.objtype is not None:
            typ_impl = var_impl.objtype
            if typ_impl.is_xml_type:
                var_impl.outconverter = \
                        lambda v: v if isinstance(v, str) else v.read()

    cdef int _fetch_rows(self, object cursor) except -1:
        """
        Internal method used for fetching rows from the database.
        """
        cdef MessageWithData message
        if self._statement._requires_full_execute:
            message = self._create_message(ExecuteMessage, cursor)
            message.num_execs = self._fetch_array_size
        else:
            message = self._create_message(FetchMessage, cursor)
        self._conn_impl._protocol._process_single_message(message)

    cdef BaseConnImpl _get_conn_impl(self):
        """
        Internal method used to return the connection implementation associated
        with the cursor implementation.
        """
        return self._conn_impl

    cdef bint _is_plsql(self):
        return self._statement._is_plsql

    cdef int _preprocess_execute(self, object conn) except -1:
        cdef BindInfo bind_info
        if self.bind_vars is not None:
            self._perform_binds(conn, 0)
        for bind_info in self._statement._bind_info_list:
            if bind_info._bind_var_impl is None:
                errors._raise_err(errors.ERR_MISSING_BIND_VALUE,
                                  name=bind_info._bind_name)

    def execute(self, cursor):
        cdef:
            object conn = cursor.connection
            MessageWithData message
        self._preprocess_execute(conn)
        message = self._create_message(ExecuteMessage, cursor)
        message.num_execs = 1
        self._conn_impl._protocol._process_single_message(message)
        self._statement._requires_full_execute = False
        if self._statement._is_query:
            self.rowcount = 0
            if message.type_cache is not None:
                message.type_cache.populate_partial_types(conn)

    def executemany(self, cursor, num_execs, batcherrors, arraydmlrowcounts):
        cdef:
            MessageWithData messsage
            Statement stmt
            uint32_t i

        # set up message to send
        self._preprocess_execute(cursor.connection)
        message = self._create_message(ExecuteMessage, cursor)
        message.num_execs = num_execs
        message.batcherrors = batcherrors
        message.arraydmlrowcounts = arraydmlrowcounts
        stmt = self._statement

        # only DML statements may use the batch errors or array DML row counts
        # flags
        if not stmt._is_dml and (batcherrors or arraydmlrowcounts):
            errors._raise_err(errors.ERR_EXECUTE_MODE_ONLY_FOR_DML)

        # if a PL/SQL statement requires a full execute, perform only a single
        # iteration in order to allow the determination of input/output binds
        # to be completed; after that, an execution of the remaining iterations
        # can be performed
        if stmt._is_plsql and stmt._requires_full_execute:
            message.num_execs = 1
            self._conn_impl._protocol._process_single_message(message)
            stmt._requires_full_execute = False
            if num_execs == 1:
                return
            message.offset = 1
            message.num_execs = num_execs - 1
        self._conn_impl._protocol._process_single_message(message)
        stmt._requires_full_execute = False

    def get_array_dml_row_counts(self):
        if self._dmlrowcounts is None:
            errors._raise_err(errors.ERR_ARRAY_DML_ROW_COUNTS_NOT_ENABLED)
        return self._dmlrowcounts

    def get_batch_errors(self):
        return self._batcherrors

    def get_bind_names(self):
        return list(self._statement._bind_info_dict.keys())

    def get_implicit_results(self, connection):
        if self._implicit_resultsets is None:
            errors._raise_err(errors.ERR_NO_STATEMENT_EXECUTED)
        return self._implicit_resultsets

    def get_lastrowid(self):
        if self.rowcount > 0:
            return _encode_rowid(&self._lastrowid)

    def is_query(self, connection):
        return self.fetch_vars is not None

    def parse(self, cursor):
        cdef MessageWithData message
        message = self._create_message(ExecuteMessage, cursor)
        message.parse_only = True
        self._conn_impl._protocol._process_single_message(message)

    def prepare(self, str sql, str tag, bint cache_statement):
        self.statement = sql
        if self._statement is not None:
            self._conn_impl._return_statement(self._statement)
            self._statement = None
        self._statement = self._conn_impl._get_statement(sql.strip(),
                                                         cache_statement)
        self.fetch_vars = self._statement._fetch_vars
        self.fetch_var_impls = self._statement._fetch_var_impls
        self._num_columns = self._statement._num_columns
