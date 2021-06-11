# Copyright 2021 Janek Bevendorff
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# distutils: language = c++

from stream_io cimport IOStream, BufferedReader

from cymove cimport cymove as move
from libcpp.string cimport string
from libcpp.utility cimport pair
from libcpp.vector cimport vector

cdef extern from "<cctype>" namespace "std" nogil:
    int isspace(int c)
    int tolower(int c)

cdef extern from "<string>" namespace "std" nogil:
    int stoi(const string& s)

cdef size_t strnpos = -1

cdef string strip_str(const string& s):
    cdef size_t start = 0
    cdef size_t end = s.size()

    for start in range(0, s.size()):
        if not isspace(s[start]):
            break

    for end in reversed(range(s.size())):
        if not isspace(s[end]):
            break

    return s.substr(start, end - start + 1)


cdef string str_to_lower(string s):
    for i in range(s.size()):
        s[i] = tolower(s[i])
    return s


cpdef enum WarcRecordType:
    warcinfo,
    response,
    resource,
    request,
    metadata,
    revisit,
    conversion,
    continuation,
    unknown = -1

cdef class WarcRecord:
    cdef WarcRecordType _record_type
    cdef vector[pair[string, string]] _headers
    cdef bint _is_http
    cdef string _http_status_line
    cdef vector[pair[string, string]] _http_headers
    cdef size_t _content_length
    cdef size_t _http_content_length
    cdef BufferedReader _reader

    def __init__(self):
        self._record_type = unknown
        self._is_http = False
        self._content_length = 0
        self._http_content_length = 0

    @property
    def record_type(self):
        return self._record_type

    @property
    def headers(self):
        return self._decode_header_map(self._headers, 'utf-8')

    @property
    def is_http(self):
        return self._is_http

    @property
    def http_status_line(self):
        return self._http_status_line.decode('iso-8859-1', errors='ignore')

    @property
    def http_headers(self):
        return self._decode_header_map(self._http_headers, 'iso-8859-1')

    @property
    def reader(self):
        return self._reader

    @property
    def content_length(self):
        return self.content_length

    @property
    def http_content_length(self):
        return self.http_content_length

    cdef _decode_header_map(self, vector[pair[string, string]]& header_map, str encoding):
        return {h.first.decode(encoding, errors='ignore'): h.second.decode(encoding, errors='ignore')
                for h in header_map}

    cdef void _set_record_type(self, string record_type):
        record_type = str_to_lower(record_type)
        if record_type == b'warcinfo':
            self._record_type = warcinfo
        elif record_type == b'response':
            self._record_type = response
        elif record_type == b'resource':
            self._record_type = resource
        elif record_type == b'request':
            self._record_type = request
        elif record_type == b'metadata':
            self._record_type = metadata
        elif record_type == b'revisit':
            self._record_type = revisit
        elif record_type == b'conversion':
            self._record_type = conversion
        elif record_type == b'continuation':
            self._record_type = continuation


cdef class ArchiveIterator:
    cdef IOStream stream
    cdef BufferedReader reader

    def __init__(self, IOStream stream):
        self.stream = stream
        self.reader = BufferedReader(self.stream)

    def __iter__(self):
        return self

    def __next__(self):
        return self.read_next_record()

    cdef vector[pair[string, string]] parse_header_block(self, bint has_status_line=False, size_t* track_bytes=NULL):
        cdef vector[pair[string, string]] headers
        cdef string line
        cdef string header_key, header_value
        cdef size_t delim_pos = 0
        cdef size_t bytes_consumed = 0

        while True:
            line = self.reader.readline()
            bytes_consumed += line.size()
            if line == b'\r\n':
                break

            if isspace(line[0]) and not headers.empty():
                # Continuation line
                headers.back().second.append(b'\n')
                headers.back().second.append(strip_str(line))
                continue

            if has_status_line:
                header_key = b''
                header_value = strip_str(line)
                has_status_line = False
            else:
                delim_pos = line.find(b':')
                if delim_pos == strnpos:
                    delim_pos = line.size() - 1
                header_key = strip_str(line.substr(0, delim_pos))
                header_value = strip_str(line.substr(delim_pos + 1))

            headers.push_back(pair[string, string](header_key, header_value))

        if track_bytes != NULL:
            track_bytes[0] = bytes_consumed
        return headers

    cdef WarcRecord read_next_record(self):
        cdef string version_line
        while True:
            version_line = self.reader.readline()
            if version_line.empty():
                # EOF
                raise StopIteration

            version_line = strip_str(version_line)
            if version_line.empty():
                # Consume empty lines
                pass
            elif version_line == b'WARC/1.0' or version_line == b'WARC/1.1':
                # OK, continue with parsing headers
                break
            else:
                # Not a WARC file or unsupported version
                raise StopIteration

        cdef WarcRecord record = WarcRecord()

        cdef vector[pair[string, string]] headers = self.parse_header_block()

        cdef string hkey
        cdef size_t parse_count = 0
        for h in headers:
            hkey = str_to_lower(h.first)
            if hkey == b'content-length':
                record._content_length = stoi(h.second)
                parse_count += 1
            elif hkey == b'warc-type':
                record._set_record_type(h.second)
                parse_count += 1
            elif hkey == b'content-type' and h.second.find(b'application/http') == 0:
                record._is_http = True

            if parse_count >= 3:
                break
        record._headers = move(headers)

        cdef size_t http_header_bytes = 0
        if record._is_http:
            record._http_headers = self.parse_header_block(True, &http_header_bytes)
            record._http_status_line = record._http_headers[0].second
            record._http_headers.erase(record._http_headers.begin())
            record._http_content_length = record._content_length - http_header_bytes

        cdef string content = self.reader.read(record._content_length - http_header_bytes)
        return record
