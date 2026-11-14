using System;
using System.Collections.Generic;
using System.Text;
using System.ComponentModel.DataAnnotations;

namespace LazyVM.Api.Business
{
    /// <summary>
    /// 
    /// </summary>
    public class LazyVM
    {
        /// <summary>
        /// 
        /// </summary>
        [Required]
        
        public String? Name
        {
            get;
            set;
        }

        public int MyProperty
        {
            get;
            set;
        }
    }
}
