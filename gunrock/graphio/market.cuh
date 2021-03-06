// ----------------------------------------------------------------------------
// Gunrock -- Fast and Efficient GPU Graph Library
// ----------------------------------------------------------------------------
// This source code is distributed under the terms of LICENSE.TXT
// in the root directory of this source distribution.
// ----------------------------------------------------------------------------

/**
 * @file
 * market.cuh
 *
 * @brief MARKET Graph Construction Routines
 */

#pragma once

#include <math.h>
#include <time.h>
#include <stdio.h>
#include <libgen.h>
#include <iostream>

#include <gunrock/graphio/utils.cuh>

namespace gunrock {
namespace graphio {

/**
 * @brief Reads a MARKET graph from an input-stream into a CSR sparse format
 *
 * Here is an example of the matrix market format
 * +----------------------------------------------+
 * |%%MatrixMarket matrix coordinate real general | <--- header line
 * |%                                             | <--+
 * |% comments                                    |    |-- 0 or more comment lines
 * |%                                             | <--+
 * |  M N L                                       | <--- rows, columns, entries
 * |  I1 J1 A(I1, J1)                             | <--+
 * |  I2 J2 A(I2, J2)                             |    |
 * |  I3 J3 A(I3, J3)                             |    |-- L lines
 * |     . . .                                    |    |
 * |  IL JL A(IL, JL)                             | <--+
 * +----------------------------------------------+
 *
 * Indices are 1-based i.2. A(1,1) is the first element.
 *
 * @param[in] f_in          Input MARKET graph file.
 * @param[in] output_file   Output file name for binary i/o.
 * @param[in] csr_graph     Csr graph object to store the graph data.
 * @param[in] undirected    Is the graph undirected or not?
 * @param[in] reversed      Whether or not the graph is inversed.
 *
 * \return If there is any File I/O error along the way.
 */
template<bool LOAD_VALUES, typename VertexId, typename Value, typename SizeT>
int ReadMarketStream(
    FILE *f_in,
    char *output_file,
    Csr<VertexId, Value, SizeT> &csr_graph,
    bool undirected,
    bool reversed,
    bool quiet = false)
{
    typedef Coo<VertexId, Value> EdgeTupleType;

    SizeT edges_read = -1;
    SizeT nodes = 0;
    SizeT edges = 0;
    EdgeTupleType *coo = NULL; // read in COO format

    time_t mark0 = time(NULL);
    if (!quiet)
    {
        printf("  Parsing MARKET COO format");
    }
    fflush(stdout);

    char line[1024];

    bool ordered_rows = true;

    while (true)
    {

        if (fscanf(f_in, "%[^\n]\n", line) <= 0)
        {
            break;
        }

        if (line[0] == '%')
        {

            // Comment

        }
        else if (edges_read == -1)
        {

            // Problem description
            long long ll_nodes_x, ll_nodes_y, ll_edges;
            if (sscanf(line, "%lld %lld %lld",
                       &ll_nodes_x, &ll_nodes_y, &ll_edges) != 3)
            {
                fprintf(stderr, "Error parsing MARKET graph:"
                        " invalid problem description.\n");
                return -1;
            }

            if (ll_nodes_x != ll_nodes_y)
            {
                fprintf(stderr,
                        "Error parsing MARKET graph: not square (%lld, %lld)\n",
                        ll_nodes_x, ll_nodes_y);
                return -1;
            }

            nodes = ll_nodes_x;
            edges = (undirected) ? ll_edges * 2 : ll_edges;

            if (!quiet)
            {
                printf(" (%lld nodes, %lld directed edges)... ",
                       (unsigned long long) ll_nodes_x,
                       (unsigned long long) ll_edges);
                fflush(stdout);
            }

            // Allocate coo graph
            unsigned long long allo_size = sizeof(EdgeTupleType);
            allo_size = allo_size * edges;
            coo = (EdgeTupleType*)malloc(allo_size);
            if (coo == NULL)
            {
                fprintf(stderr, "Error parsing MARKET graph:"
                    "coo allocation failed, sizeof(EdgeTupleType) = %d, edges = %lld, allo_size = %lld\n", sizeof(EdgeTupleType), edges, allo_size);
                return -1;
            }

            edges_read++;

        }
        else
        {

            // Edge description (v -> w)
            if (!coo)
            {
                fprintf(stderr, "Error parsing MARKET graph: invalid format\n");
                return -1;
            }
            if (edges_read >= edges)
            {
                fprintf(stderr,
                        "Error parsing MARKET graph:"
                        "encountered more than %d edges\n",
                        edges);
                if (coo) free(coo);
                return -1;
            }

            long long ll_row, ll_col, ll_value;
            // Value ll_value;  // used for parse float / double
            int num_input;
            if (LOAD_VALUES)
            {
                if ((num_input = sscanf(
                                     line, "%lld %lld %lld",
                                     &ll_row, &ll_col, &ll_value)) < 2)
                {
                    fprintf(stderr,
                            "Error parsing MARKET graph: badly formed edge\n");
                    if (coo) free(coo);
                    return -1;
                }
                else if (num_input == 2)
                {
                    ll_value = rand() % 64;
                }
            }
            else
            {
                if (sscanf(line, "%lld %lld", &ll_row, &ll_col) != 2)
                {
                    fprintf(stderr,
                            "Error parsing MARKET graph: badly formed edge\n");
                    if (coo) free(coo);
                    return -1;
                }
            }

            if (LOAD_VALUES)
            {
                coo[edges_read].val = ll_value;
            }
            if (reversed && !undirected)
            {
                coo[edges_read].col = ll_row - 1;   // zero-based array
                coo[edges_read].row = ll_col - 1;   // zero-based array
                ordered_rows = false;
            }
            else
            {
                coo[edges_read].row = ll_row - 1;   // zero-based array
                coo[edges_read].col = ll_col - 1;   // zero-based array
                ordered_rows = false;
            }

            edges_read++;

            if (undirected)
            {
                // Go ahead and insert reverse edge
                coo[edges_read].row = ll_col - 1;       // zero-based array
                coo[edges_read].col = ll_row - 1;       // zero-based array

                if (LOAD_VALUES)
                {
                    coo[edges_read].val = ll_value;
                }

                ordered_rows = false;
                edges_read++;
            }
        }
    }

    if (coo == NULL)
    {
        fprintf(stderr, "No graph found\n");
        return -1;
    }

    if (edges_read != edges)
    {
        fprintf(stderr,
                "Error parsing MARKET graph: only %d/%d edges read\n",
                edges_read, edges);
        if (coo) free(coo);
        return -1;
    }

    time_t mark1 = time(NULL);
    if (!quiet)
    {
        printf("Done parsing (%ds).\n", (int) (mark1 - mark0));
        fflush(stdout);
    }

    // Convert COO to CSR
    csr_graph.template FromCoo<LOAD_VALUES>(output_file, coo,
                                            nodes, edges, ordered_rows,
                                            undirected, reversed, quiet);

    free(coo);
    fflush(stdout);

    return 0;
}

/**
 * @brief Read csr arrays directly instead of transfer from coo format
 * @param[in] f_in          Input graph file name.
 * @param[in] csr_graph     Csr graph object to store the graph data.
 * @param[in] undirected    Is the graph undirected or not?
 * @param[in] reversed      Whether or not the graph is inversed.
 */
template <bool LOAD_VALUES, typename VertexId, typename Value, typename SizeT>
int ReadCsrArrays(char *f_in, Csr<VertexId, Value, SizeT> &csr_graph,
                  bool undirected, bool reversed, bool quiet)
{
    csr_graph.template FromCsr<LOAD_VALUES>(f_in, quiet);
    return 0;
}


/**
 * \defgroup Public Interface
 * @{
 */

/**
 * @brief Loads a MARKET-formatted CSR graph from the specified file.
 *
 * @param[in] mm_filename Graph file name, if empty, it is loaded from STDIN.
 * @param[in] output_file Output file name for binary i/o.
 * @param[in] csr_graph Reference to CSR graph object. @see Csr
 * @param[in] undirected Is the graph undirected or not?
 * @param[in] reversed Is the graph reversed or not?
 * @param[in] quiet If true, print no output
 *
 * \return If there is any File I/O error along the way. 0 for no error.
 */
template<bool LOAD_VALUES, typename VertexId, typename Value, typename SizeT>
int BuildMarketGraph(
    char *mm_filename,
    char *output_file,
    Csr<VertexId, Value, SizeT> &csr_graph,
    bool undirected,
    bool reversed,
    bool quiet = false)
{
    FILE *_file = fopen(output_file, "r");
    if (_file)
    {
        fclose(_file);
        if (ReadCsrArrays<LOAD_VALUES>(
                    output_file, csr_graph, undirected, reversed, quiet) != 0)
        {
            return -1;
        }
    }
    else
    {
        if (mm_filename == NULL)
        {
            // Read from stdin
            if (!quiet)
            {
                printf("Reading from stdin:\n");
            }
            if (ReadMarketStream<LOAD_VALUES>(
                        stdin, output_file, csr_graph, undirected, reversed) != 0)
            {
                return -1;
            }
        }
        else
        {
            // Read from file
            FILE *f_in = fopen(mm_filename, "r");
            if (f_in)
            {
                if (!quiet)
                {
                    printf("Reading from %s:\n", mm_filename);
                }
                if (ReadMarketStream<LOAD_VALUES>(
                            f_in, output_file, csr_graph,
                            undirected, reversed, quiet) != 0)
                {
                    fclose(f_in);
                    return -1;
                }
                fclose(f_in);
            }
            else
            {
                perror("Unable to open file");
                return -1;
            }
        }
    }
    return 0;
}

/**
 * @brief read in graph function read in graph according to its type.
 *
 * @tparam LOAD_VALUES
 * @tparam VertexId
 * @tparam Value
 * @tparam SizeT
 *
 * @param[in] file_in    Input MARKET graph file.
 * @param[in] graph      CSR graph object to store the graph data.
 * @param[in] undirected Is the graph undirected or not?
 * @param[in] reversed   Whether or not the graph is inversed.
 * @param[in] quiet     Don't print out anything to stdout
 *
 * \return int Whether error occurs (0 correct, 1 error)
 */
template <bool LOAD_VALUES, typename VertexId, typename Value, typename SizeT>
int BuildMarketGraph(
    char *file_in,
    Csr<VertexId, Value, SizeT> &graph,
    bool undirected,
    bool reversed,
    bool quiet = false)
{
    // seperate the graph path and the file name
    char *temp1 = strdup(file_in);
    char *temp2 = strdup(file_in);
    char *file_path = dirname (temp1);
    char *file_name = basename(temp2);

    if (undirected)
    {
        char ud[256];  // undirected graph
        sprintf(ud, "%s/.%s.ud.%d.bin", file_path, file_name, (LOAD_VALUES?1:0));
        if (BuildMarketGraph<LOAD_VALUES>(file_in, ud, graph,
                    true, false, quiet) != 0)
            return 1;
    }
    else if (!undirected && reversed)
    {
        char rv[256];  // reversed graph
        sprintf(rv, "%s/.%s.rv.%d.bin", file_path, file_name, (LOAD_VALUES?1:0));
        if (BuildMarketGraph<LOAD_VALUES>(file_in, rv, graph,
                    false, true, quiet) != 0)
            return 1;
    }
    else if (!undirected && !reversed)
    {
        char di[256];  // directed graph
        sprintf(di, "%s/.%s.di.%d.bin", file_path, file_name, (LOAD_VALUES?1:0));
        if (BuildMarketGraph<LOAD_VALUES>(file_in, di, graph,
                    false, false, quiet) != 0)
            return 1;
    }
    else
    {
        fprintf(stderr, "Unspecified Graph Type.\n");
        return 1;
    }
    return 0;
}

/**@}*/

} // namespace graphio
} // namespace gunrock

// Leave this at the end of the file
// Local Variables:
// mode:c++
// c-file-style: "NVIDIA"
// End:
