/*
 * Copyright (c) 2019, NVIDIA CORPORATION.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#pragma once

#include <cudf/column/column_device_view.cuh>
#include <cudf/sorting.hpp>
#include <cudf/table/table_device_view.cuh>
#include <cudf/utils/traits.hpp>
#include <cudf/utils/type_dispatcher.hpp>
#include <utilities/release_assert.cuh>

namespace cudf {

namespace exp {

/**---------------------------------------------------------------------------*
 * @brief Result type of the `element_relational_comparator` function object.
 *
 * Indicates how two elements `a` and `b` compare with one and another.
 *
 * Equivalence is defined as `not (a<b) and not (b<a)`. Elements that are are
 * EQUIVALENT may not necessarily be *equal*.
 *
 *---------------------------------------------------------------------------**/
enum class weak_ordering {
  LESS,        ///< Indicates `a` is less than (ordered before) `b`
  EQUIVALENT,  ///< Indicates `a` is neither less nor greater than `b`
  GREATER      ///< Indicates `a` is greater than (ordered after) `b`
};

/**---------------------------------------------------------------------------*
 * @brief Performs a relational comparison between two elements in two columns.
 *
 * @tparam has_nulls Indicates the potential for null values in either column.
 *---------------------------------------------------------------------------**/
template <bool has_nulls = true>
struct element_relational_comparator {
  /**---------------------------------------------------------------------------*
   * @brief Checks how two elements in two columns compare with each other.
   *
   * @param lhs The column containing the first element
   * @param lhs_element_index The index of the first element
   * @param rhs The column containing the second element (may be equal to `lhs`)
   * @param rhs_element_index The index of the second element
   * @param size_of_nulls Indicates how null values compare with all other
   * values
   * @return weak_ordering Indicates the relationship between the elements in
   * the `lhs` and `rhs` columns.
   *---------------------------------------------------------------------------**/
  template <typename Element, std::enable_if_t<cudf::is_relationally_comparable<
                                  Element, Element>()>* = nullptr>
  __device__ weak_ordering operator()(column_device_view lhs,
                                      size_type lhs_element_index,
                                      column_device_view rhs,
                                      size_type rhs_element_index,
                                      null_size size_of_nulls) {
    if (has_nulls) {
      bool const lhs_is_null{lhs.nullable() and lhs.is_null(lhs_element_index)};
      bool const rhs_is_null{rhs.nullable() and rhs.is_null(rhs_element_index)};

      if (lhs_is_null and rhs_is_null) {  // null <? null
        return weak_ordering::EQUIVALENT;
      } else if (lhs_is_null) {  // null <? x
        return (size_of_nulls == null_size::LOWEST) ? weak_ordering::LESS
                                                    : weak_ordering::GREATER;
      } else if (rhs_is_null) {  // x <? null
        return (size_of_nulls == null_size::HIGHEST) ? weak_ordering::LESS
                                                     : weak_ordering::GREATER;
      }
    }

    Element const lhs_element = lhs.data<Element>()[lhs_element_index];
    Element const rhs_element = rhs.data<Element>()[rhs_element_index];

    if (lhs_element < rhs_element) {
      return weak_ordering::LESS;
    } else if (rhs_element < lhs_element) {
      return weak_ordering::GREATER;
    }
    return weak_ordering::EQUIVALENT;
  }

  template <typename Element,
            std::enable_if_t<not cudf::is_relationally_comparable<
                Element, Element>()>* = nullptr>
  __device__ weak_ordering operator()(column_device_view lhs,
                                      size_type lhs_element_index,
                                      column_device_view rhs,
                                      size_type rhs_element_index) {
    release_assert(false &&
                   "Attempted to compare elements of uncomparable types.");
  }
};

/**---------------------------------------------------------------------------*
 * @brief Computes if one row is lexicographically *less* than another row.
 *
 * Lexicographic ordering is determined by:
 * - Two rows are compared element by element.
 * - The first mismatching element defines which row is lexicographically less
 * or greater than the other.
 *
 * Lexicographic ordering is exactly equivalent to doing an alphabetical sort of
 * two words, for example, `aac` would be *less* than (or precede) `abb`. The
 * second letter in both words is the first non-equal letter, and `a < b`, thus
 * `aac < abb`.
 *
 * @tparam has_nulls Indicates the potential for null values in either row.
 *---------------------------------------------------------------------------**/
template <bool has_nulls = true>
class row_lexicographic_comparator {
 public:
  /**---------------------------------------------------------------------------*
   * @brief Construct a function object for comparing the rows between two
   * tables.
   *
   * @throws cudf::logic_error if `lhs.num_columns() != rhs.num_columns()`
   *
   * @param lhs The first table
   * @param rhs The second table (may be the same table as `lhs`)
   * @param size_of_nulls Indicates how null values compare to all other values.
   * @param column_order Optional, device array the same length as a row that
   * indicates the desired ascending/descending order of each column in a row.
   * If `nullptr`, it is assumed all columns are sorted in ascending order.
   *---------------------------------------------------------------------------**/
  row_lexicographic_comparator(table_device_view lhs, table_device_view rhs,
                               null_size size_of_nulls = null_size::LOWEST,
                               order* column_order = nullptr)
      : _lhs{lhs},
        _rhs{rhs},
        _size_of_nulls{size_of_nulls},
        _column_order{column_order} {
    CUDF_EXPECTS(_lhs.num_columns() == _rhs.num_columns(),
                 "Mismatched number of columns.");
  }

  /**---------------------------------------------------------------------------*
   * @brief Checks if the row at `lhs_index` in the `lhs` table compares
   * lexicographically less than the row at `rhs_index` in the `rhs` table.
   *
   * @param lhs_index The index of row in the `lhs` table to examine
   * @param rhs_index The index of the row in the `rhs` table to examine
   * @return `true` if row from the `lhs` table compares less than row in the
   * `rhs` table
   *---------------------------------------------------------------------------**/
  __device__ bool operator()(size_type lhs_index, size_type rhs_index) const
      noexcept {
    for (size_type i = 0; i < _lhs.num_columns(); ++i) {
      bool ascending =
          (_column_order == nullptr) or (_column_order[i] == order::ASCENDING);

      weak_ordering state{weak_ordering::EQUIVALENT};

      if (ascending) {
        state = cudf::exp::type_dispatcher(
            _lhs.column(i).type(), element_relational_comparator<has_nulls>{},
            _lhs.column(i), lhs_index, _rhs.column(i), rhs_index,
            _size_of_nulls);
      } else {
        state = cudf::exp::type_dispatcher(
            _lhs.column(i).type(), element_relational_comparator<has_nulls>{},
            _rhs.column(i), rhs_index, _lhs.column(i), lhs_index,
            _size_of_nulls);
      }

      if (state == weak_ordering::EQUIVALENT) {
        continue;
      }

      return (state == weak_ordering::LESS) ? true : false;
    }
    return false;
  }

 private:
  table_device_view _lhs;
  table_device_view _rhs;
  null_size _size_of_nulls{null_size::LOWEST};
  order const* _column_order{};
};

}  // namespace exp
}  // namespace cudf
