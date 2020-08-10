// TODO: describe interconnections between the PE's.
`ifndef PIPELINE_SV
`define PIPELINE_SV

module systolic_array (
	//inputs
    input clk,
    input reset,

	input READS base_reads,
    //input logic [`NUM_PROCS-1:0] [63:0] prior_match, // quality scores for if the reads match <=== in the PRIORS struct now
    //input logic [`NUM_PROCS-1:0] [63:0] prior_neq,   // quality scores for if the reads differ
    input PRIORS prior_reads,
    input logic [$clog2(`MAX_STRING_LENGTH)-1:0] string_length, y_length, //the length of the strings
    input transition_probs tp,


    //outputs
    output logic complete,      //complete asserts when all computation is finished
    output logic [$clog2(`MAX_STRING_LENGTH)-1:0] read_index_x, read_index_y,
    output logic read_x_valid, read_y_valid,
    output logic [63:0] final_val,
    output logic [`NUM_PROCS-1:0] enables,
    output logic advance_out, sweep_out
);

logic [`NUM_PROCS-1:0] next_enables; // controls enable signal for each PE
logic [`NUM_PROCS-1:0] tb_specials;
logic [`NUM_PROCS-1:0] dones;
logic [`NUM_PROCS-1:0] ignore;
logic advance, sweep; // tells every PE to move over one
logic [`NUM_PROCS-1:0] [63:0] pe_priors, next_pe_priors; // the chosen prior to be passed to PE
logic [$clog2(`MAX_STRING_LENGTH)-1:0] true_num_procs; //the number of processors we can activate

pe_calcs [`NUM_PROCS-1:0] pe_calcs_buffers; // used to handoff pe_calcs between PEs
// PE_n will read from pe_calcs_buffers[n] to get its dependencies
// PE_0 will be an edge case where the values in pe_calcs_buffers[0] will be pre-calculated
// multidimensional as each PE must store 2 pe_calcs for the next PE
// will need to shift when advance is high
pe_calcs last_pe_output;
pe_calcs [`MAX_STRING_LENGTH-1:0] last_pe_checkpoint, next_last_pe_checkpoint; // only used if computation requires multiple passes, 
                                                      // stores the computations from the last PE

logic [$clog2(`MAX_STRING_LENGTH)-1:0] pass_counter, next_pass_counter, bases_remaining, y_offset, next_y_offset; //which pass we are on


STRING [`NUM_PROCS-1:0] ref_read, next_ref_read; //shift register that stores up to NUM_PROCS bases of the reference
STRING [`NUM_PROCS-1:0] experimental, next_experimental; //buffer for holding experimental read bases currently being used

logic [`MAX_COUNT_WIDTH-1:0] counter, next_counter; //counter for determining PE enables
logic [$clog2(`MAX_STRING_LENGTH)-1:0] y_counter, next_y_counter; // need special behavior for the y index
PRIORS [`NUM_PROCS-1:0] priors_buffer, next_priors_buffer;

ARRAY_STATE state, next_state;
logic make_final_write, next_make_final_write;

//variables for the final adder
logic [63:0] input_a, input_b, temp_final_val, next_temp_result, temp_result;
logic input_valid, temp_complete, reset_addr;

assign advance_out = advance;
assign sweep_out = sweep;

generate
    genvar i;
        for(i = 0; i < `NUM_PROCS-1; ++i) begin : pes
            processing_element pe(
                .clk(clk),
                .reset(reset),
                .advance(advance),
                .enable(enables[i]),
                .set_tb_special(tb_specials[i]),
                .ignore_my_vals(ignore[i]),
                .probs(tp),
                .prior(pe_priors[i]),
                .pe_vals_in(pe_calcs_buffers[i]),

                .pe_vals_out(pe_calcs_buffers[i+1]),
                .done(dones[i])
            );
        end : pes
endgenerate

processing_element pe_last(
    .clk(clk),
    .reset(reset),
    .advance(advance),
    .enable(enables[`NUM_PROCS-1]),
    .set_tb_special(tb_specials[`NUM_PROCS-1]),
    .ignore_my_vals(ignore[`NUM_PROCS-1]),
    .probs(tp),
    .prior(pe_priors[`NUM_PROCS-1]),
    .pe_vals_in(pe_calcs_buffers[`NUM_PROCS-1]),

    .pe_vals_out(last_pe_output), //this will write into the checkpoint if multi pass is needed
    .done(dones[`NUM_PROCS-1])
);

double_adder result_adder(
    .input_a(input_a),
    .input_b(input_b),
	.input_valid(input_valid),
    .clk(clk),
    .reset(reset_addr),
    .output_z(temp_final_val),
    .done(temp_complete)
);



always_comb begin
    next_counter = counter;
    next_state = state;
    next_enables = enables;
    next_pass_counter = pass_counter;
    next_ref_read = ref_read;
    next_pe_priors = pe_priors;
    next_last_pe_checkpoint = last_pe_checkpoint;
    read_x_valid = 0;
    read_y_valid = 0;
    read_index_x = 0;
    read_index_y = 0;
    advance = 0;
    sweep = 0;

    input_a = 0;
    input_b = 0;
    input_valid = 0;
    complete = 0;
    final_val = 0;
    reset_addr = 0;
    next_temp_result = temp_result;
    tb_specials = 0;
    next_experimental = experimental;
    next_y_counter = y_counter;
    next_priors_buffer = priors_buffer;
    ignore = 0;
    next_y_offset = y_offset;
    next_make_final_write = make_final_write;

    bases_remaining = y_length - pass_counter;

    true_num_procs = `NUM_PROCS; //limit the number of PEs to the minimum dimension
    if(`NUM_PROCS > y_length || `NUM_PROCS > string_length) begin
        true_num_procs = y_length;
        if(y_length > string_length) begin
            true_num_procs = string_length;
        end
    end


    pe_calcs_buffers[0] = 0;
    //special case to make fm(0,0) = 1
    if(pass_counter == 0 && counter == 1) begin
        tb_specials[0] = 1'b1;
        pe_calcs_buffers[0].t_b = tp.a_mm;
        //pe_calcs_buffers[0].m_val = 64'h3f800000;
    end



    if(y_offset > 0) begin
        if(counter > string_length) begin
            pe_calcs_buffers[0] = true_num_procs == string_length ? last_pe_output : last_pe_checkpoint[counter - string_length - 1];
            ignore[counter - string_length-1] = 1; 
        end

        else if(counter == true_num_procs) begin
            ignore[true_num_procs-1] = 1;
            pe_calcs_buffers[0] = true_num_procs == string_length ? last_pe_output : last_pe_checkpoint[counter-1];
            
        end

        else begin
            pe_calcs_buffers[0] = true_num_procs == string_length ? last_pe_output : last_pe_checkpoint[counter - 1];
        end

    end
    


    case(state)

        INIT_RUN: begin //fetch x and y
            read_index_x = 0;
            read_index_y = 0;
            read_x_valid = 1;
            read_y_valid = 1; 
            /*
            //if we just wrapped around, write the most recent result from the last PE into the last checkpoint index
            if(pass_counter > 0) begin
                next_last_pe_checkpoint[string_length-1] = last_pe_output;
                sweep = 1;
            end
            */

            next_state = INIT_RUN2;
        end

        INIT_RUN2: begin 

            
            
            if(prior_reads.valid && base_reads.valid)begin
                
                next_enables[0] = 1; //only enable the first PE
                next_priors_buffer[0] = prior_reads;

                //arbitrate the prior for the first PE
		
                if(base_reads.reference == base_reads.exp)
                    next_pe_priors[0] = prior_reads.match;

                else 
                    next_pe_priors[0] = prior_reads.neq;
                //push in the first reference base
                next_ref_read[0] = base_reads.reference;

                //push in the first experimental base
                next_experimental[0] = base_reads.exp;

                next_state = FETCH_DATA;
            end


            
        end

        //while computation is happening, in the background...
        FETCH_DATA: begin //fetch the next x
            
            //read the index modulo the string length (this only works if NUM_PROCS <= string_length)
            read_index_x = counter >= string_length ? counter - string_length : counter;
            read_x_valid = 1;
            if(counter < true_num_procs || counter >= string_length) begin
                read_index_y = y_counter + y_offset;
                read_y_valid = 1;
            end
            
            next_state = WAIT;
            
            //write the previous result of the last PE into the checkpoint
            if(enables[true_num_procs-1] || make_final_write) begin
                next_make_final_write = 0; 
                if(counter == true_num_procs && y_offset > 0)begin
                    next_last_pe_checkpoint[string_length-1] = last_pe_output;
                end
                else begin
                    next_last_pe_checkpoint[counter - true_num_procs-1] = last_pe_output;
                end
            end

        end

        WAIT: begin
            //use the enables to check dones
            for(int i=0; i < `NUM_PROCS; ++i)begin
                if(enables[i] && ~dones[i])
                    break;
                else if(i == `NUM_PROCS-1) begin //if we've seen all the dones we're looking for
                    advance = 1;
                    next_counter = counter + 1;
                    next_state = FETCH_DATA;

                    //shift in the next reference base, the next experimental base and choose priors
                    next_ref_read[0] = base_reads.reference;
                    for(int i = 0; i < `NUM_PROCS-1; ++i) begin
                        next_ref_read[i+1] = ref_read[i];
                    end

                    
                    if(counter < true_num_procs || counter >= string_length) begin
                        //we made a read in y so write it in
                        next_experimental[y_counter] = base_reads.exp;
                        next_priors_buffer[y_counter] = prior_reads;
                        next_y_counter = y_counter + 1;
                    end   
                    //if PE0 will compute the last column next, the next fetch will be for the first column
                    if(counter == string_length-1 || (true_num_procs == string_length && counter == (string_length <<1) - 1)) begin
                        next_y_offset = y_offset + true_num_procs;
                        next_y_counter = 0;
                    end
                    
                    
                    
                    //if the final PE is about to overlaps
                    if(counter == string_length + true_num_procs-1) begin
                        next_counter = true_num_procs;
                        next_pass_counter = pass_counter + true_num_procs;
                    end
                    
                    

                    //set next_enables based on the next_counter value
                    for(int i=0; i < `NUM_PROCS; ++i)begin
                        //enable PEs during the first pass
                        if(next_counter > i && y_offset == 0) begin
                            next_enables[i] = 1;
                        end
                        //when a PE walks off, disable those who are leaving the matrix
                        if(counter - i  >= string_length && enables[i]) begin
                            if(i + y_offset > y_length-1)begin
                                next_enables[i] = 0;
                                //if we just disabled the PE writing the checkpoint, set a flag so it can be written the next cycle
                                next_make_final_write = (i == true_num_procs-1);
                            end
                        end
                            

                    end

                    //if we just finished the last sweep nobody will be enabled next cycle
                    if(next_enables == 0) begin
                        next_state = RESULT;
			            reset_addr = 1;
                        next_pass_counter = pass_counter;
		            end

                    //set priors based on comparison between exp and next_ref_read values
                    //might need to change to i-1 if this becomes critical path
                    for(int i=0; i < `NUM_PROCS; ++i) begin
                        if(next_ref_read[i] == next_experimental[i]) 
                            next_pe_priors[i] = next_priors_buffer[i].match;
                        else
                            next_pe_priors[i] = next_priors_buffer[i].neq;
                    end
                    
                end

            end    
            
        end //WAIT state

        RESULT: begin
            input_a = bases_remaining == `NUM_PROCS ? last_pe_output.m_val : pe_calcs_buffers[bases_remaining].m_val;
            input_b = bases_remaining == `NUM_PROCS ? last_pe_output.i_val : pe_calcs_buffers[bases_remaining].i_val;
            input_valid = 1;

            if(temp_complete) begin
                next_temp_result = temp_final_val;
                reset_addr = 1;
                next_state = RESULT_2;
            end
        end

        RESULT_2: begin
            input_a = temp_result;
            input_b = bases_remaining == `NUM_PROCS ? last_pe_output.d_val : pe_calcs_buffers[bases_remaining].d_val;
            input_valid = 1;
            
            complete = temp_complete;
            final_val = temp_final_val;


        end
    endcase
end

always_ff @(posedge clk) begin
    if(reset) begin
        counter <= 1;
        y_counter <= 1;
        enables <= 0;
        state <= INIT_RUN;
        pass_counter <= 0;
        ref_read <= {`NUM_PROCS-1{STRING_T}};
        experimental <= {`NUM_PROCS-1{STRING_T}};
        pe_priors <= 0;
        last_pe_checkpoint <= 0; 
        temp_result <= 0;
        priors_buffer <= 0;
        y_offset <= 0;
        make_final_write <= 0;
    end 
    else begin
        counter <= next_counter;
        enables <= next_enables;
        state <= next_state;
        pass_counter <= next_pass_counter;
        ref_read <= next_ref_read;
        pe_priors <= next_pe_priors;
        last_pe_checkpoint <= next_last_pe_checkpoint;
        temp_result <= next_temp_result;
        experimental <= next_experimental;
        y_counter <= next_y_counter;
        priors_buffer <= next_priors_buffer;
        y_offset <= next_y_offset;
        make_final_write <= next_make_final_write;
    end
end

endmodule
`endif