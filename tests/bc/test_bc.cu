// ----------------------------------------------------------------
// Gunrock -- Fast and Efficient GPU Graph Library
// ----------------------------------------------------------------
// This source code is distributed under the terms of LICENSE.TXT
// in the root directory of this source distribution.
// ----------------------------------------------------------------

/**
 * @file
 * test_bc.cu
 *
 * @brief Simple test driver program for BC.
 */

#include <stdio.h>
#include <string>
#include <deque>
#include <vector>
#include <queue>
#include <iostream>
#include <fstream>
#include <algorithm>

// Utilities and correctness-checking
#include <gunrock/util/test_utils.cuh>

// BC includes
#include <gunrock/app/bc/bc_enactor.cuh>
#include <gunrock/app/bc/bc_problem.cuh>
#include <gunrock/app/bc/bc_functor.cuh>

// Operator includes
#include <gunrock/oprtr/advance/kernel.cuh>
#include <gunrock/oprtr/filter/kernel.cuh>

#include <moderngpu.cuh>

// Boost includes
#include <boost/config.hpp>
#include <boost/graph/adjacency_list.hpp>
#include <boost/graph/connected_components.hpp>
#include <boost/graph/bc_clustering.hpp>
#include <boost/graph/iteration_macros.hpp>

using namespace gunrock;
using namespace gunrock::app;
using namespace gunrock::util;
using namespace gunrock::oprtr;
using namespace gunrock::app::bc;

/******************************************************************************
 * Housekeeping Routines
 ******************************************************************************/
void Usage()
{
    printf(
        "test <graph-type> [graph-type-arguments]\n"
        "Graph type and graph type arguments:\n"
        "    market <matrix-market-file-name>\n"
        "        Reads a Matrix-Market coordinate-formatted graph of\n"
        "        directed/undirected edges from STDIN (or from the\n"
        "        optionally-specified file).\n"
        "    rmat (default: rmat_scale = 10, a = 0.57, b = c = 0.19)\n"
        "        Generate R-MAT graph as input\n"
        "        --rmat_scale=<vertex-scale>\n"
        "        --rmat_nodes=<number-nodes>\n"
        "        --rmat_edgefactor=<edge-factor>\n"
        "        --rmat_edges=<number-edges>\n"
        "        --rmat_a=<factor> --rmat_b=<factor> --rmat_c=<factor>\n"
        "        --rmat_seed=<seed>\n"
        "    rgg (default: rgg_scale = 10, rgg_thfactor = 0.55)\n"
        "        Generate Random Geometry Graph as input\n"
        "        --rgg_scale=<vertex-scale>\n"
        "        --rgg_nodes=<number-nodes>\n"
        "        --rgg_thfactor=<threshold-factor>\n"
        "        --rgg_threshold=<threshold>\n"
        "        --rgg_vmultipiler=<vmultipiler>\n"
        "        --rgg_seed=<seed>\n\n"
        "Optional arguments:\n"
        "[--device=<device_index>] Set GPU(s) for testing (Default: 0).\n"
        "[--instrumented]          Keep kernels statics [Default: Disable].\n"
        "                          total_queued, search_depth and barrier duty.\n"
        "                          (a relative indicator of load imbalance.)\n"
        "[--src=<Vertex-ID|randomize|largestdegree>]\n"
        "                          Begins traversal from the source (Default: 0).\n"
        "                          If randomize: from a random source vertex.\n"
        "                          If largestdegree: from largest degree vertex.\n"
        "[--quick]                 Skip the CPU reference validation process.\n"
        "[--mark-pred]             Keep both label info and predecessor info.\n"
        "[--disable-size-check]    Disable frontier queue size check.\n"
        "[--grid-size=<grid size>] Maximum allowed grid size setting.\n"
        "[--queue-sizing=<factor>] Allocates a frontier queue sized at: \n"
        "                          (graph-edges * <factor>). (Default: 1.0)\n"
        "[--in-sizing=<in/out_queue_scale_factor>]\n"
        "                          Allocates a frontier queue sized at: \n"
        "                          (graph-edges * <factor>). (Default: 1.0)\n"
        "[--v]                     Print verbose per iteration debug info.\n"
        "[--iteration-num=<num>]   Number of runs to perform the test.\n"
        "[--traversal-mode=<0|1>]  Set traversal strategy, 0 for Load-Balanced\n"
        "                          1 for Dynamic-Cooperative (Default: dynamic\n"
        "                          determine based on average degree).\n"
        "[--partition_method=<random|biasrandom|clustered|metis>]\n"
        "                          Choose partitioner (Default use random).\n"
        "[--ref-file=<file_name>]  Use pre-computed result in file to verify.\n"
        "[--quiet]                 No output (unless --json is specified).\n"
        "[--json]                  Output JSON-format statistics to STDOUT.\n"
        "[--jsonfile=<name>]       Output JSON-format statistics to file <name>\n"
        "[--jsondir=<dir>]         Output JSON-format statistics to <dir>/name,\n"
        "                          where name is auto-generated.\n"
    );
}

/**
 * @brief Displays the BC result (sigma value and BC value)
 *
 * @tparam Value
 * @tparam SizeT
 *
 * @param[in] sigmas
 * @param[in] bc_values
 * @param[in] nodes
 */
template<typename Value, typename SizeT>
void DisplaySolution(Value *sigmas, Value *bc_values, SizeT nodes)
{
    if (nodes < 40)
    {
        printf("[");
        for (SizeT i = 0; i < nodes; ++i)
        {
            PrintValue(i);
            printf(":");
            PrintValue(sigmas[i]);
            printf(",");
            PrintValue(bc_values[i]);
            printf(" ");
        }
        printf("]\n");
    }
}

/******************************************************************************
* BC Testing Routines
*****************************************************************************/

/**
 * @brief Graph edge properties (bundled properties)
 */
struct EdgeProperties
{
    int weight;
};

/**
 * @brief A simple CPU-based reference BC ranking implementation.
 *
 * @tparam VertexId
 * @tparam Value
 * @tparam SizeT
 *
 * @param[in] graph Reference to graph we process on
 * @param[in] bc_values Pointer to node bc value
 * @param[in] ebc_values Pointer to edge bc value
 * @param[in] sigmas Pointer to node sigma value
 * @param[in] source_path Pointer to a vector to store CPU computed labels for each node
 * @param[in] src VertexId of source node if there is any
 * @param[in] quiet Don't print out anything to stdout
 */
template <
    typename VertexId,
    typename Value,
    typename SizeT >
void ReferenceBC(
    const Csr<VertexId, Value, SizeT> &graph,
    Value                             *bc_values,
    Value                             *ebc_values,
    Value                             *sigmas,
    VertexId                          *source_path,
    VertexId                           src,
    bool                               quiet = false)
{
    typedef Coo<VertexId, Value> EdgeTupleType;
    EdgeTupleType *coo = (EdgeTupleType*) malloc(sizeof(EdgeTupleType) * graph.edges);
    if (src == -1)
    {
        // Perform full exact BC using BGL

        using namespace boost;
        typedef adjacency_list <setS, vecS, undirectedS, no_property,
                EdgeProperties> Graph;
        typedef Graph::vertex_descriptor Vertex;
        typedef Graph::edge_descriptor Edge;

        Graph G;
        for (int i = 0; i < graph.nodes; ++i)
        {
            for (int j = graph.row_offsets[i]; j < graph.row_offsets[i + 1]; ++j)
            {
                add_edge(vertex(i, G), vertex(graph.column_indices[j], G), G);
            }
        }

        typedef std::map<Edge, int> StdEdgeIndexMap;
        StdEdgeIndexMap my_e_index;
        typedef boost::associative_property_map< StdEdgeIndexMap > EdgeIndexMap;
        EdgeIndexMap e_index(my_e_index);

        int i = 0;
        BGL_FORALL_EDGES(edge, G, Graph)
        {
            my_e_index.insert(std::pair<Edge, int>(edge, i));
            ++i;
        }

        // Define EdgeCentralityMap
        std::vector< double > e_centrality_vec(boost::num_edges(G), 0.0);
        // Create the external property map
        boost::iterator_property_map< std::vector< double >::iterator,
              EdgeIndexMap >
              e_centrality_map(e_centrality_vec.begin(), e_index);

        // Define VertexCentralityMap
        typedef boost::property_map< Graph, boost::vertex_index_t>::type
        VertexIndexMap;
        VertexIndexMap v_index = get(boost::vertex_index, G);
        std::vector< double > v_centrality_vec(boost::num_vertices(G), 0.0);

        // Create the external property map
        boost::iterator_property_map< std::vector< double >::iterator,
              VertexIndexMap>
              v_centrality_map(v_centrality_vec.begin(), v_index);

        // Perform BC
        CpuTimer cpu_timer;
        cpu_timer.Start();
        brandes_betweenness_centrality(G, v_centrality_map, e_centrality_map);
        cpu_timer.Stop();
        float elapsed = cpu_timer.ElapsedMillis();

        BGL_FORALL_VERTICES(vertex, G, Graph)
        {
            bc_values[vertex] = (Value)v_centrality_map[vertex];
        }

        int idx = 0;
        BGL_FORALL_EDGES(edge, G, Graph)
        {
            coo[idx].row = source(edge, G);
            coo[idx].col = target(edge, G);
            coo[idx++].val = (Value)e_centrality_map[edge];
            coo[idx].col = source(edge, G);
            coo[idx].row = target(edge, G);
            coo[idx++].val = (Value)e_centrality_map[edge];
        }

        std::stable_sort(coo, coo + graph.edges,
                         RowFirstTupleCompare<EdgeTupleType>);

        for (idx = 0; idx < graph.edges; ++idx)
        {
            //std::cout << coo[idx].row << "," << coo[idx].col
            //          << ":" << coo[idx].val << std::endl;
            //ebc_values[idx] = coo[idx].val;
        }

        if (!quiet)
        {
            printf("CPU BC finished in %lf msec.", elapsed);
        }
    }
    else
    {
        // Simple BFS pass to get single pass BC
        // VertexId *source_path = new VertexId[graph.nodes];

        // Initialize distances
        for (VertexId i = 0; i < graph.nodes; ++i)
        {
            source_path[i] = -1;
            bc_values[i] = 0;
            sigmas[i] = 0;
        }
        source_path[src] = 0;
        VertexId search_depth = 0;
        sigmas[src] = 1;

        // Initialize queue for managing previously-discovered nodes
        std::deque<VertexId> frontier;
        frontier.push_back(src);

        //
        // Perform one pass of BFS for one source
        //

        CpuTimer cpu_timer;
        cpu_timer.Start();
        while (!frontier.empty())
        {
            // Dequeue node from frontier
            VertexId dequeued_node = frontier.front();
            frontier.pop_front();
            VertexId neighbor_dist = source_path[dequeued_node] + 1;

            // Locate adjacency list
            int edges_begin = graph.row_offsets[dequeued_node];
            int edges_end = graph.row_offsets[dequeued_node + 1];

            for (int edge = edges_begin; edge < edges_end; ++edge)
            {
                // Lookup neighbor and enqueue if undiscovered
                VertexId neighbor = graph.column_indices[edge];
                if (source_path[neighbor] == -1)
                {
                    source_path[neighbor] = neighbor_dist;
                    sigmas[neighbor] += sigmas[dequeued_node];
                    if (search_depth < neighbor_dist)
                    {
                        search_depth = neighbor_dist;
                    }

                    frontier.push_back(neighbor);
                }
                else
                {
                    if (source_path[neighbor] == source_path[dequeued_node] + 1)
                        sigmas[neighbor] += sigmas[dequeued_node];
                }
            }
        }
        search_depth++;

        for (int iter = search_depth - 2; iter > 0; --iter)
        {

            int cur_level = 0;
            for (int node = 0; node < graph.nodes; ++node)
            {
                if (source_path[node] == iter)
                {
                    ++cur_level;
                    int edges_begin = graph.row_offsets[node];
                    int edges_end = graph.row_offsets[node + 1];

                    for (int edge = edges_begin; edge < edges_end; ++edge)
                    {
                        VertexId neighbor = graph.column_indices[edge];
                        if (source_path[neighbor] == iter + 1)
                        {
                            bc_values[node] +=
                                1.0f * sigmas[node] / sigmas[neighbor] *
                                (1.0f + bc_values[neighbor]);
                        }
                    }
                }
            }
        }

        for (int i = 0; i < graph.nodes; ++i)
        {
            bc_values[i] *= 0.5f;
        }

        cpu_timer.Stop();
        float elapsed = cpu_timer.ElapsedMillis();

        if (!quiet)
        {
            printf("CPU BC finished in %lf msec. Search depth: %d\n",
                   elapsed, search_depth);
        }

        //delete[] source_path;
    }
    free(coo);
}

/**
 * @brief RunTests entry
 *
 * @tparam VertexId
 * @tparam Value
 * @tparam SizeT
 * @tparam INSTRUMENT
 * @tparam DEBUG
 * @tparam SIZE_CHECK
 *
 * @param[in] info Pointer to info contains parameters and statistics.
 */
template <
    typename VertexId,
    typename Value,
    typename SizeT,
    bool INSTRUMENT,
    bool DEBUG,
    bool SIZE_CHECK >
void RunTests(Info<VertexId, Value, SizeT> *info)
{
    typedef BCProblem < VertexId,
            SizeT,
            Value,
            true,   // MARK_PREDECESSORS
            false > BcProblem;  //does not use double buffer

    typedef BCEnactor < BcProblem,
            INSTRUMENT,
            DEBUG,
            SIZE_CHECK >
            BcEnactor;

    // parse configurations from mObject info
    Csr<VertexId, Value, SizeT> *graph = info->csr_ptr;
    VertexId src                 = info->info["source_vertex"].get_int64();
    bool quiet_mode              = info->info["quiet_mode"].get_bool();
    int max_grid_size            = info->info["max_grid_size"].get_int();
    int num_gpus                 = info->info["num_gpus"].get_int();
    double max_queue_sizing      = info->info["max_queue_sizing"].get_real();
    double max_queue_sizing1     = info->info["max_queue_sizing1"].get_real();
    double max_in_sizing         = info->info["max_in_sizing"].get_real();
    std::string partition_method = info->info["partition_method"].get_str();
    double partition_factor      = info->info["partition_factor"].get_real();
    int partition_seed           = info->info["partition_seed"].get_int();
    bool quick_mode              = info->info["quick_mode"].get_bool();
    bool stream_from_host        = info->info["stream_from_host"].get_bool();
    int iterations               = 1; // force to 1 info->info["num_iteration"].get_int();
    std::string ref_filename     = info->info["ref_filename"].get_str();

    json_spirit::mArray device_list = info->info["device_list"].get_array();
    int* gpu_idx = new int[num_gpus];
    for (int i = 0; i < num_gpus; i++) gpu_idx[i] = device_list[i].get_int();

    // TODO: remove after merge mgpu-cq
    ContextPtr   *context = (ContextPtr*)  info->context;
    cudaStream_t *streams = (cudaStream_t*)info->streams;

    // Allocate host-side array (for both reference and GPU-computed results)
    Value        *reference_bc_values        = new Value   [graph->nodes];
    Value        *reference_ebc_values       = new Value   [graph->edges];
    Value        *reference_sigmas           = new Value   [graph->nodes];
    VertexId     *reference_labels           = new VertexId[graph->nodes];
    Value        *h_sigmas                   = new Value   [graph->nodes];
    Value        *h_bc_values                = new Value   [graph->nodes];
    Value        *h_ebc_values               = new Value   [graph->edges];
    VertexId     *h_labels                   = new VertexId[graph->nodes];
    Value        *reference_check_bc_values  = (quick_mode)                ? NULL : reference_bc_values;
    Value        *reference_check_ebc_values = (quick_mode || (src != -1)) ? NULL : reference_ebc_values;
    Value        *reference_check_sigmas     = (quick_mode || (src == -1)) ? NULL : reference_sigmas;
    VertexId     *reference_check_labels     = (quick_mode || (src == -1)) ? NULL : reference_labels;

    size_t *org_size = new size_t[num_gpus];
    for (int gpu = 0; gpu < num_gpus; gpu++)
    {
        size_t dummy;
        cudaSetDevice(gpu_idx[gpu]);
        cudaMemGetInfo(&(org_size[gpu]), &dummy);
    }

    BcEnactor* enactor = new BcEnactor(num_gpus, gpu_idx);  // enactor map
    BcProblem* problem = new BcProblem;  // allocate problem on GPU

    util::GRError(problem->Init(
                      stream_from_host,
                      graph,
                      NULL,
                      num_gpus,
                      gpu_idx,
                      partition_method,
                      streams,
                      max_queue_sizing,
                      max_in_sizing,
                      partition_factor,
                      partition_seed),
                  "BC Problem Initialization Failed", __FILE__, __LINE__);

    util::GRError(enactor->Init(context, problem, max_grid_size),
                  "BC Enactor init failed", __FILE__, __LINE__);

    // compute reference CPU BC solution for source-distance
    if (reference_check_bc_values != NULL)
    {
        if (ref_filename.empty())
        {
            if (!quiet_mode) { printf("Computing reference value ...\n"); }
            ReferenceBC(
                *graph,
                reference_check_bc_values,
                reference_check_ebc_values,
                reference_check_sigmas,
                reference_check_labels,
                src,
                quiet_mode);
            if (!quiet_mode) { printf("\n"); }
        }
        else
        {
            std::ifstream fin;
            fin.open(ref_filename.c_str(), std::ios::binary);
            for (int i = 0; i < graph->nodes; ++i)
            {
                fin.read(reinterpret_cast<char*>(&reference_check_bc_values[i]), sizeof(Value));
            }
            fin.close();
        }
    }

    // perform BC
    double elapsed  = 0.0f;
    CpuTimer cpu_timer;

    VertexId start_src, end_src;
    if (src == -1)
    {
        start_src = 0;
        end_src = graph->nodes;
    }
    else
    {
        start_src = src;
        end_src = src + 1;
    }

    for (int iter = 0; iter < iterations; ++iter)
    {
        if (!quiet_mode)
        {
            printf("iteration:%d\n", iter);
        }
        for (int gpu = 0; gpu < num_gpus; gpu++)
        {
            util::SetDevice(gpu_idx[gpu]);
            util::MemsetKernel <<< 128, 128>>>(
                problem->data_slices[gpu]->bc_values.GetPointer(util::DEVICE),
                (Value)0.0f, (int)(problem->sub_graphs[gpu].nodes));
        }
        util::GRError(problem->Reset(
                          0, enactor->GetFrontierType(),
                          max_queue_sizing, max_queue_sizing1),
                      "BC Problem Data Reset Failed", __FILE__, __LINE__);

        if (!quiet_mode)
        {
            printf("__________________________\n"); fflush(stdout);
        }
        cpu_timer.Start();
        for (VertexId i = start_src; i < end_src; ++i)
        {
            util::GRError(problem->Reset(
                              i, enactor->GetFrontierType(),
                              max_queue_sizing, max_queue_sizing1),
                          "BC Problem Data Reset Failed", __FILE__, __LINE__);
            util::GRError(enactor ->Reset(),
                          "BC Enactor Reset failed", __FILE__, __LINE__);
            util::GRError(enactor ->Enact(i),
                          "BC Problem Enact Failed", __FILE__, __LINE__);
        }
        for (int gpu = 0; gpu < num_gpus; gpu++)
        {
            util::SetDevice(gpu_idx[gpu]);
            util::MemsetScaleKernel <<< 128, 128>>>(
                problem->data_slices[gpu]->bc_values.GetPointer(util::DEVICE),
                (Value)0.5f, (int)(problem->sub_graphs[gpu].nodes));
        }
        cpu_timer.Stop();
        if (!quiet_mode)
        {
            printf("--------------------------\n"); fflush(stdout);
        }
        elapsed += cpu_timer.ElapsedMillis();
    }

    elapsed /= iterations;

    // Copy out results
    util::GRError(problem->Extract(
                      h_sigmas, h_bc_values, h_ebc_values, h_labels),
                  "BC Problem Data Extraction Failed", __FILE__, __LINE__);

    // Verify the result
    if (reference_check_bc_values != NULL)
    {
        //util::cpu_mt::PrintCPUArray<SizeT, Value>("reference_check_bc_values", reference_check_bc_values, graph->nodes);
        //util::cpu_mt::PrintCPUArray<SizeT, Value>("bc_values", h_bc_values, graph->nodes);
        if (!quiet_mode) { printf("Validity BC Value: "); }
        int num_error = CompareResults(
                            h_bc_values, reference_check_bc_values,
                            graph->nodes, true, quiet_mode);
        if (num_error > 0)
        {
            if (!quiet_mode) { printf("Number of errors occurred: %d\n", num_error); }
        }
        if (!quiet_mode) { printf("\n"); }
    }
    if (reference_check_ebc_values != NULL)
    {
        if (!quiet_mode) { printf("Validity Edge BC Value: "); }
        int num_error = CompareResults(
                            h_ebc_values, reference_check_ebc_values,
                            graph->edges, true, quiet_mode);
        if (num_error > 0)
        {
            if (!quiet_mode) { printf("Number of errors occurred: %d\n", num_error); }
        }
        if (!quiet_mode) { printf("\n"); }
    }
    if (reference_check_sigmas != NULL)
    {
        if (!quiet_mode) { printf("Validity Sigma: "); }
        int num_error = CompareResults(
                            h_sigmas, reference_check_sigmas,
                            graph->nodes, true, quiet_mode);
        if (num_error > 0)
        {
            if (!quiet_mode)
            {
                printf("Number of errors occurred: %d\n", num_error);
            }
        }
        if (!quiet_mode) { printf("\n"); }
    }
    if (reference_check_labels != NULL)
    {
        if (!quiet_mode) { printf("Validity labels: "); }
        int num_error = CompareResults(
                            h_labels, reference_check_labels,
                            graph->nodes, true, quiet_mode);
        if (num_error > 0)
        {
            if (!quiet_mode)
            {
                printf("Number of errors occurred: %d\n", num_error);
            }
        }
        if (!quiet_mode) { printf("\n"); }
    }

    if (!quiet_mode)
    {
        // Display Solution
        DisplaySolution(h_sigmas, h_bc_values, graph->nodes);
    }

    info->ComputeTraversalStats(  // compute running statistics
        enactor->enactor_stats.GetPointer(), elapsed, h_labels);

    if (!quiet_mode)
    {
        info->DisplayStats();  // display collected statistics
    }

    info->CollectInfo();  // collected all the info and put into JSON mObject

    if (!quiet_mode)
    {
        printf("\n\tMemory Usage(B)\t");
        for (int gpu = 0; gpu < num_gpus; gpu++)
            if (num_gpus > 1) {if (gpu != 0) printf(" #keys%d,0\t #keys%d,1\t #ins%d,0\t #ins%d,1", gpu, gpu, gpu, gpu); else printf(" #keys%d,0\t #keys%d,1", gpu, gpu);}
            else printf(" #keys%d,0\t #keys%d,1", gpu, gpu);
        if (num_gpus > 1) printf(" #keys%d", num_gpus);
        printf("\n");
        double max_queue_sizing_[2] = {0, 0}, max_in_sizing_ = 0;
        for (int gpu = 0; gpu < num_gpus; gpu++)
        {
            size_t gpu_free, dummy;
            cudaSetDevice(gpu_idx[gpu]);
            cudaMemGetInfo(&gpu_free, &dummy);
            printf("GPU_%d\t %ld", gpu_idx[gpu], org_size[gpu] - gpu_free);
            for (int i = 0; i < num_gpus; i++)
            {
                for (int j = 0; j < 2; j++)
                {
                    SizeT x = problem->data_slices[gpu]->frontier_queues[i].keys[j].GetSize();
                    printf("\t %lld", (long long) x);
                    double factor = 1.0 * x / (num_gpus > 1 ? problem->graph_slices[gpu]->in_counter[i] : problem->graph_slices[gpu]->nodes);
                    if (factor > max_queue_sizing_[j]) max_queue_sizing_[j] = factor;
                }
                if (num_gpus > 1 && i != 0 )
                    for (int t = 0; t < 2; t++)
                    {
                        SizeT x = problem->data_slices[gpu][0].keys_in[t][i].GetSize();
                        printf("\t %lld", (long long) x);
                        double factor = 1.0 * x / problem->graph_slices[gpu]->in_counter[i];
                        if (factor > max_in_sizing_) max_in_sizing_ = factor;
                    }
            }
            if (num_gpus > 1) printf("\t %lld", (long long)(problem->data_slices[gpu]->frontier_queues[num_gpus].keys[0].GetSize()));
            printf("\n");
        }
        printf("\t queue_sizing =\t %lf \t %lf", max_queue_sizing_[0], max_queue_sizing_[1]);
        if (num_gpus > 1) printf("\t in_sizing =\t %lf", max_in_sizing_);
        printf("\n");
    }

    // Cleanup
    if (org_size            ) {delete[] org_size            ; org_size             = NULL;}
    if (problem             ) {delete   problem             ; problem              = NULL;}
    if (enactor             ) {delete   enactor             ; enactor              = NULL;}
    if (reference_sigmas    ) {delete[] reference_sigmas    ; reference_sigmas     = NULL;}
    if (reference_bc_values ) {delete[] reference_bc_values ; reference_bc_values  = NULL;}
    if (reference_ebc_values) {delete[] reference_ebc_values; reference_ebc_values = NULL;}
    if (reference_labels    ) {delete[] reference_labels    ; reference_labels     = NULL;}
    if (h_sigmas            ) {delete[] h_sigmas            ; h_sigmas             = NULL;}
    if (h_bc_values         ) {delete[] h_bc_values         ; h_bc_values          = NULL;}
    if (h_ebc_values        ) {delete[] h_ebc_values        ; h_ebc_values         = NULL;}
    if (h_labels            ) {delete[] h_labels            ; h_labels             = NULL;}
}

/**
 * @brief RunTests entry
 *
 * @tparam VertexId
 * @tparam Value
 * @tparam SizeT
 * @tparam INSTRUMENT
 * @tparam DEBUG
 *
 * @param[in] info Pointer to info contains parameters and statistics.
 */
template <
    typename      VertexId,
    typename      Value,
    typename      SizeT,
    bool          INSTRUMENT,
    bool          DEBUG >
void RunTests_size_check(Info<VertexId, Value, SizeT> *info)
{
    if (info->info["size_check"].get_bool())
    {
        RunTests<VertexId, Value, SizeT, INSTRUMENT, DEBUG,  true>(info);
    }
    else
    {
        RunTests<VertexId, Value, SizeT, INSTRUMENT, DEBUG, false>(info);
    }
}

/**
 * @brief RunTests entry
 *
 * @tparam VertexId
 * @tparam Value
 * @tparam SizeT
 * @tparam INSTRUMENT
 *
 * @param[in] info Pointer to info contains parameters and statistics.
 */
template <
    typename    VertexId,
    typename    Value,
    typename    SizeT,
    bool        INSTRUMENT >
void RunTests_debug(Info<VertexId, Value, SizeT> *info)
{
    if (info->info["debug_mode"].get_bool())
    {
        RunTests_size_check<VertexId, Value, SizeT, INSTRUMENT,  true>(info);
    }
    else
    {
        RunTests_size_check<VertexId, Value, SizeT, INSTRUMENT, false>(info);
    }
}

/**
 * @brief Test entry
 *
 * @tparam VertexId
 * @tparam Value
 * @tparam SizeT
 *
 * @param[in] info Pointer to info contains parameters and statistics.
 */
template <
    typename      VertexId,
    typename      Value,
    typename      SizeT >
void RunTests_instrumented(Info<VertexId, Value, SizeT> *info)
{
    if (info->info["instrument"].get_bool())
    {
        RunTests_debug<VertexId, Value, SizeT,  true>(info);
    }
    else
    {
        RunTests_debug<VertexId, Value, SizeT, false>(info);
    }
}

/******************************************************************************
 * Main
 ******************************************************************************/

int main(int argc, char** argv)
{
    CommandLineArgs args(argc, argv);
    int graph_args = argc - args.ParsedArgc() - 1;
    if (argc < 2 || graph_args < 1 || args.CheckCmdLineFlag("help"))
    {
        Usage();
        return 1;
    }

    typedef int VertexId;  // Use int as the vertex identifier
    typedef float Value;   // Use float as the value type
    typedef int SizeT;     // Use int as the graph size type

    Csr<VertexId, Value, SizeT> csr(false);  // graph we process on
    Info<VertexId, Value, SizeT> *info = new Info<VertexId, Value, SizeT>;

    // graph construction or generation related parameters
    info->info["undirected"] = true;  // require undirected input graph

    info->Init("BC", args, csr);  // initialize Info structure
    RunTests_instrumented<VertexId, Value, SizeT>(info);  // run test

    return 0;
}

// Leave this at the end of the file
// Local Variables:
// mode:c++
// c-file-style: "NVIDIA"
// End:
